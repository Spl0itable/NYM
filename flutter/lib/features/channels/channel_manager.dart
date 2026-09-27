import '../../models/channel.dart';

/// User geographic location used for proximity sorting (`this.userLocation`).
class UserLocation {
  const UserLocation({required this.lat, required this.lng});
  final double lat;
  final double lng;
}

/// Inputs to the channel sort, gathered from app_state's companion maps.
/// Keys are channel keys (geohash or name, lowercase) per docs/specs/03 §1.2.
class ChannelSortContext {
  const ChannelSortContext({
    required this.activeKey,
    required this.pinned,
    required this.lastActivity,
    required this.unreadCounts,
    this.sortByProximity = false,
    this.userLocation,
  });

  /// The currently-active channel key (sorts second, after #nymchat).
  final String activeKey;

  /// Pinned channel keys (`nym_pinned_channels`).
  final Set<String> pinned;

  /// channel key → last-activity ms (`nym_channel_activity`).
  final Map<String, int> lastActivity;

  /// channel key → unread count (`nym_unread_counts`).
  final Map<String, int> unreadCounts;

  /// `settings.sortByProximity` — only then does proximity ordering apply.
  final bool sortByProximity;

  /// Resolved geolocation (null when unavailable / permission denied).
  final UserLocation? userLocation;
}

/// Pure channel registry/list logic mirroring `js/modules/channels.js`:
/// the exact sort priority (`sortChannelsByActivity`, channels.js:1794) and the
/// add/remove/pin/hide/block mutations over the persisted KV list sets
/// (docs/specs/03 §1.2–§1.6).
class ChannelManager {
  ChannelManager._();

  /// The activity-map / unread-map key for a [ChannelEntry] — always the
  /// `#`-prefixed storage key, matching channels.js's
  /// `a.dataset.geohash ? '#'+gh : a.dataset.channel` lookup against
  /// `channelLastActivity` / `unreadCounts` (which are stored `#`-prefixed).
  static String activityKey(ChannelEntry c) => c.storageKey;

  /// Sorts [channels] by the PWA's sequential priority
  /// (`sortChannelsByActivity`):
  /// 1. `#nymchat` always first.
  /// 2. the currently-active channel next.
  /// 3. pinned channels (kept as a band; within the band they order by the
  ///    same proximity/activity/unread rules below — the PWA does not
  ///    alphabetize pinned channels).
  /// 4. proximity (only when `sortByProximity && userLocation`): valid-geohash
  ///    pairs by Haversine distance to [UserLocation].
  /// 5. fallback: `channelLastActivity` desc, tiebreak `unreadCounts` desc.
  ///
  /// Returns a new sorted list; the input is not mutated.
  static List<ChannelEntry> sortChannels(
    List<ChannelEntry> channels,
    ChannelSortContext ctx,
  ) {
    final out = [...channels];
    out.sort((a, b) => _compare(a, b, ctx));
    return out;
  }

  static int _compare(ChannelEntry a, ChannelEntry b, ChannelSortContext ctx) {
    // 1) #nymchat always first.
    final aDefault = a.key == kDefaultChannel;
    final bDefault = b.key == kDefaultChannel;
    if (aDefault && !bDefault) return -1;
    if (!aDefault && bDefault) return 1;

    // 2) active channel next.
    final aActive = a.key == ctx.activeKey;
    final bActive = b.key == ctx.activeKey;
    if (aActive && !bActive) return -1;
    if (!aActive && bActive) return 1;

    // 3) pinned band. Pinned channels float above unpinned, but WITHIN the band
    //    the PWA does NOT alphabetize — it falls through to the same
    //    proximity/activity/unread ordering as every other channel
    //    (sortChannelsByActivity, channels.js:1819 only checks pinned vs not).
    final aPinned = ctx.pinned.contains(a.key);
    final bPinned = ctx.pinned.contains(b.key);
    if (aPinned && !bPinned) return -1;
    if (!aPinned && bPinned) return 1;

    // 4) proximity (only valid-geohash pairs, only when enabled + located).
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

    // 5) fallback: activity desc, then unread desc.
    final aAct = ctx.lastActivity[activityKey(a)] ?? 0;
    final bAct = ctx.lastActivity[activityKey(b)] ?? 0;
    if (aAct != bAct) return bAct - aAct;
    final aUnread = ctx.unreadCounts[activityKey(a)] ?? 0;
    final bUnread = ctx.unreadCounts[activityKey(b)] ?? 0;
    return bUnread - aUnread;
  }
}

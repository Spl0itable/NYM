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
    final keyed = _keysOf(channels, ctx)..sort(_compare);
    return [for (final k in keyed) k.entry];
  }

  static List<_SortKey> _keysOf(
      List<ChannelEntry> channels, ChannelSortContext ctx) {
    final pins = <String, int>{};
    for (final k in ctx.pinned) {
      pins.putIfAbsent(k, () => pins.length);
    }
    final loc = ctx.sortByProximity ? ctx.userLocation : null;
    return [
      for (final (i, c) in channels.indexed) _SortKey.of(c, ctx, pins, loc, i),
    ];
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
    if (a.unread != b.unread) return b.unread - a.unread;
    return a.joined - b.joined;
  }
}

class ChannelOrder {
  List<ChannelEntry> _channels = const [];
  List<_SortKey> _byJoin = const [];
  List<_SortKey> _sorted = const [];
  String _activeKey = '';
  List<String> _pinned = const [];
  bool _byDistance = false;
  int _fullSorts = 0;

  int get fullSorts => _fullSorts;

  List<ChannelEntry> sort(List<ChannelEntry> channels, ChannelSortContext ctx) {
    final byDistance = ctx.sortByProximity && ctx.userLocation != null;
    if (byDistance || _byDistance || !_sameList(channels, ctx)) {
      return _full(channels, ctx, byDistance);
    }
    final moved = <_SortKey>[];
    for (var i = 0; i < _byJoin.length; i++) {
      final k = _byJoin[i];
      final activity = ctx.lastActivity[k.storageKey] ?? 0;
      final unread = ctx.unreadCounts[k.storageKey] ?? 0;
      if (activity == k.activity && unread == k.unread) continue;
      k.moved = true;
      moved.add(_byJoin[i] = k.withCounts(activity, unread));
    }
    if (moved.isNotEmpty) {
      moved.sort(ChannelManager._compare);
      final rest = [
        for (final k in _sorted)
          if (!k.moved) k
      ];
      final out = <_SortKey>[];
      var from = 0;
      for (final k in moved) {
        var lo = from;
        var hi = rest.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (ChannelManager._compare(rest[mid], k) < 0) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        out
          ..addAll(rest.getRange(from, lo))
          ..add(k);
        from = lo;
      }
      out.addAll(rest.getRange(from, rest.length));
      _sorted = out;
    }
    return [for (final k in _sorted) k.entry];
  }

  bool _sameList(List<ChannelEntry> channels, ChannelSortContext ctx) {
    if (channels.length != _channels.length ||
        ctx.activeKey != _activeKey ||
        ctx.pinned.length != _pinned.length) {
      return false;
    }
    var i = 0;
    for (final k in ctx.pinned) {
      if (k != _pinned[i++]) return false;
    }
    for (i = 0; i < channels.length; i++) {
      if (!identical(channels[i], _channels[i])) return false;
    }
    return true;
  }

  List<ChannelEntry> _full(
      List<ChannelEntry> channels, ChannelSortContext ctx, bool byDistance) {
    _fullSorts++;
    _channels = [...channels];
    _activeKey = ctx.activeKey;
    _pinned = [...ctx.pinned];
    _byDistance = byDistance;
    _byJoin = ChannelManager._keysOf(channels, ctx);
    _sorted = [..._byJoin]..sort(ChannelManager._compare);
    return [for (final k in _sorted) k.entry];
  }
}

class _SortKey {
  _SortKey(this.entry, this.storageKey, this.isDefault, this.pin, this.active,
      this.distance, this.activity, this.unread, this.joined);

  factory _SortKey.of(
    ChannelEntry entry,
    ChannelSortContext ctx,
    Map<String, int> pins,
    UserLocation? loc,
    int joined,
  ) {
    final key = entry.key;
    final storageKey = ChannelManager.activityKey(entry);
    return _SortKey(
      entry,
      storageKey,
      key == kDefaultChannel,
      pins[key] ?? -1,
      key == ctx.activeKey,
      _distance(entry, loc),
      ctx.lastActivity[storageKey] ?? 0,
      ctx.unreadCounts[storageKey] ?? 0,
      joined,
    );
  }

  _SortKey withCounts(int activity, int unread) => _SortKey(entry, storageKey,
      isDefault, pin, active, distance, activity, unread, joined);

  final ChannelEntry entry;
  final String storageKey;
  final bool isDefault;
  final int pin;
  final bool active;
  final double? distance;
  final int activity;
  final int unread;
  final int joined;
  bool moved = false;

  static double? _distance(ChannelEntry c, UserLocation? loc) {
    if (loc == null || c.geohash.isEmpty || !isValidGeohash(c.geohash)) {
      return null;
    }
    final at = decodeGeohash(c.geohash);
    return calculateDistance(loc.lat, loc.lng, at.lat, at.lng);
  }
}

import 'package:flutter/foundation.dart';

import '../../models/channel.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';

/// A geohash channel plotted on the globe: its decoded center, recent message
/// count (drives the heatmap weight), and whether the user has joined it.
/// Mirrors the PWA's `geohashChannels[]` entries (geohash, lat, lng, messages,
/// isJoined).
@immutable
class GeohashChannelPoint {
  const GeohashChannelPoint({
    required this.geohash,
    required this.lat,
    required this.lng,
    required this.messages,
    required this.isJoined,
  });

  final String geohash;
  final double lat;
  final double lng;

  /// Recent message count within the active window.
  final int messages;
  final bool isJoined;
}

/// Builds the plotted geohash channels from [state], counting messages within
/// the last [windowHours] hours per geohash (mirrors `updateGeohashChannels`).
///
/// Read-only over [AppState]; gracefully returns an empty list when there are no
/// geohash channels or no recent activity. Geohash channels come from both the
/// registered channel list and any geohash-tagged messages in the store.
List<GeohashChannelPoint> buildGeohashChannels(
  AppState state, {
  required int windowHours,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final cutoffMs = nowMs - windowHours * 3600 * 1000;

  // geohash -> recent message count.
  final counts = <String, int>{};

  void tallyFromList(String geohash, List<Message> list) {
    var n = 0;
    for (final m in list) {
      if (m.timestamp >= cutoffMs) n++;
    }
    counts[geohash] = (counts[geohash] ?? 0) + n;
  }

  // Registered geohash channels (ensure they appear even with zero activity).
  for (final c in state.channels) {
    if (!c.isGeohash) continue;
    final gh = c.geohash.toLowerCase();
    counts.putIfAbsent(gh, () => 0);
    final list = state.messages['#$gh'];
    if (list != null) tallyFromList(gh, list);
  }

  // Any geohash-tagged messages whose channel isn't registered.
  state.messages.forEach((key, list) {
    if (!key.startsWith('#')) return;
    final name = key.substring(1).toLowerCase();
    if (!isValidGeohash(name) || name == kDefaultChannel) return;
    if (counts.containsKey(name)) return; // already tallied above
    counts.putIfAbsent(name, () => 0);
    tallyFromList(name, list);
  });

  if (counts.isEmpty) return const [];

  final joined = state.channels
      .where((c) => c.isGeohash)
      .map((c) => c.geohash.toLowerCase())
      .toSet();

  final out = <GeohashChannelPoint>[];
  counts.forEach((gh, n) {
    final center = decodeGeohash(gh);
    out.add(GeohashChannelPoint(
      geohash: gh,
      lat: center.lat,
      lng: center.lng,
      messages: n,
      isJoined: joined.contains(gh),
    ));
  });
  return out;
}

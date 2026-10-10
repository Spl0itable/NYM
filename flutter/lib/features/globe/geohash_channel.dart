import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/channel.dart';
import '../../state/app_state.dart';
import 'geo_explore.dart';

/// A geohash channel on the globe: center, recent message heat and joined state.
@immutable
class GeohashChannelPoint extends GeoActivity {
  const GeohashChannelPoint({
    required super.geohash,
    required super.lat,
    required super.lng,
    required super.messages,
    required this.isJoined,
    this.lastActivityMs = 0,
  });

  final bool isJoined;

  final int lastActivityMs;
}

/// Seed geohash channels always offered as globe candidates; inlined to avoid importing nostr_controller.dart.
const List<String> kGlobeSeedGeohashes = [
  'nymchat',
  '9q',
  'w2',
  'dr5r',
  '9q8y',
  'u4pr',
  'gcpv',
  'f2m6',
  'xn77',
  'tjm5',
];

/// Minimum heat for a geohash D1 reports active in-window but that has no hourly buckets, so it still plots.
const int kD1ActiveHeatFloor = 1;

/// Plotted channels whose heat is the sum over the window of `max(local[i], d1[i])` per hour.
List<GeohashChannelPoint> buildGeohashChannels(
  AppState state, {
  required int windowHours,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final cutoffMs = nowMs - windowHours * 3600 * 1000;

  final counts = <String, int>{};
  final lastMs = <String, int>{};

  // Candidates: seeds, registered channels, channels with messages, and D1-active geohashes; all gated on in-window activity.
  final candidates = <String>{};

  for (final g in kGlobeSeedGeohashes) {
    final gh = g.toLowerCase();
    if (isValidGeohash(gh) && gh != kDefaultChannel) candidates.add(gh);
  }

  for (final c in state.channels) {
    if (!c.isGeohash) continue;
    candidates.add(c.geohashKey.toLowerCase());
  }

  state.messages.forEach((key, list) {
    if (!key.startsWith('#')) return;
    final name = key.substring(1).toLowerCase();
    if (!isValidGeohash(name) || name == kDefaultChannel) return;
    candidates.add(name);
  });

  // Keyed `#<channel>`; only valid geohash keys are candidates.
  state.channelLastActivity.forEach((storageKey, _) {
    if (!storageKey.startsWith('#')) return;
    final name = storageKey.substring(1).toLowerCase();
    if (!isValidGeohash(name) || name == kDefaultChannel) return;
    candidates.add(name);
  });

  candidates.removeWhere(state.isChannelHidden);
  if (candidates.isEmpty) return const [];

  final n = math.max(1, math.min(24, windowHours));
  for (final gh in candidates) {
    // Hourly buckets aligned with D1 (index 0 = latest); spam-gated messages don't count.
    final localBuckets = List<int>.filled(24, 0);
    final list = state.messages['#$gh'];
    var newest = state.channelLastActivity['#$gh'] ?? 0;
    if (list != null) {
      for (final m in list) {
        if (m.spamGated || state.isMessageFiltered(m)) continue;
        final ts = m.timestamp;
        if (ts <= 0) continue;
        if (ts > newest) newest = ts;
        var ageH = (nowMs - ts) ~/ (3600 * 1000);
        if (ageH < 0) ageH = 0;
        if (ageH < 24) localBuckets[ageH]++;
      }
    }
    final d1Buckets = state.geohashD1Activity[gh];
    var total = 0;
    for (var i = 0; i < n; i++) {
      final local = localBuckets[i];
      final d1c =
          (d1Buckets != null && i < d1Buckets.length) ? d1Buckets[i] : 0;
      total += math.max(local, d1c);
    }
    // D1-active in window but no hourly buckets: plot at the presence floor; real buckets win.
    if (total < 1 && (d1Buckets == null || d1Buckets.isEmpty)) {
      final d1LastMs = state.channelLastActivity['#$gh'] ?? 0;
      if (d1LastMs >= cutoffMs) total = kD1ActiveHeatFloor;
    }
    counts[gh] = total;
    lastMs[gh] = newest;
  }

  // Joined = registered channels plus pinned, so favorited geohashes show "Go to Channel" instead of "Join".
  final joined = <String>{
    for (final c in state.channels)
      if (c.isGeohash) c.geohashKey.toLowerCase(),
    for (final k in state.pinnedChannels)
      if (isValidGeohash(k)) k.toLowerCase(),
  };

  final out = <GeohashChannelPoint>[];
  counts.forEach((gh, n) {
    // Only geohashes with at least one in-window message are plotted.
    if (n < 1) return;
    final center = decodeGeohash(gh);
    out.add(GeohashChannelPoint(
      geohash: gh,
      lat: center.lat,
      lng: center.lng,
      messages: n,
      isJoined: joined.contains(gh),
      lastActivityMs: lastMs[gh] ?? 0,
    ));
  });
  return out;
}

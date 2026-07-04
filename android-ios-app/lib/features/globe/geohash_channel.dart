import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/channel.dart';
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

/// The well-known seed geohash channels the PWA always offers as globe/sidebar
/// candidates (`this.commonGeohashes`, app.js:681 — also iterated by
/// `updateGeohashChannels`/`fetchGeohashActivityFromD1`, channels.js:53/139).
/// `nymchat` is the named default (never a valid geohash) so it self-filters out
/// of the globe. Inlined here — matching the existing duplication in
/// `autocomplete_queries.dart` / `settings_helpers.dart` — to avoid importing the
/// heavy `nostr_controller.dart` into this leaf module.
const List<String> kGlobeSeedGeohashes = [
  'nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5',
];

/// Heat floor assigned to a geohash that is D1-active inside the active window
/// but has no locally-loaded messages (see [buildGeohashChannels]). The native
/// store keeps no per-geohash hourly D1 buckets — `applyChannelActivity`
/// (app_state.dart) folds the PWA's `_geohashD1Activity` buckets into
/// `channelLastActivity` (a single last-seen ms) + `unreadCounts`, discarding the
/// per-hour counts — so we can't reproduce the PWA's `max(local[i], d1[i])`
/// per-bucket sum exactly. Instead, when D1 reports activity for a geohash within
/// the window we surface this minimum non-zero weight so the channel plots at all
/// (the PWA-faithful fallback called out in the GL1 spec).
const int kD1ActiveHeatFloor = 1;

/// Builds the plotted geohash channels from [state], counting messages within
/// the last [windowHours] hours per geohash (mirrors `updateGeohashChannels`,
/// channels.js:46-110).
///
/// Read-only over [AppState]; gracefully returns an empty list when there are no
/// geohash channels or no recent activity. Candidate geohashes are gathered like
/// the PWA's `allGeohashes` set (channels.js:50-75): the seed
/// [kGlobeSeedGeohashes], registered channels, geohash-tagged messages in the
/// store, AND any geohash D1 reported activity for (via `channelLastActivity`).
///
/// Per-geohash weight is the PWA's `_combineGeohashActivity`: bucket local
/// messages into 24 hourly slots and sum `max(local[i], d1[i])` across the
/// window (channels.js:113-125), where `d1[i]` is the per-hour D1 count kept in
/// [AppState.geohashD1Activity] (C05-3). A geohash with D1 activity inside the
/// window but no per-hour buckets (e.g. discovered only via last-activity) falls
/// back to a [kD1ActiveHeatFloor] presence floor so it still plots.
List<GeohashChannelPoint> buildGeohashChannels(
  AppState state, {
  required int windowHours,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final cutoffMs = nowMs - windowHours * 3600 * 1000;

  // geohash -> recent message heat (Σ per-hour max of local + D1 buckets).
  final counts = <String, int>{};

  // The candidate geohash set, mirroring the PWA's `allGeohashes`:
  //   1. seed (common) geohashes (channels.js:53),
  //   2. registered geohash channels (channels.js:56-60),
  //   3. geohash-tagged channels with stored messages (channels.js:63-67),
  //   4. geohashes D1 reported activity for (channels.js:71-74) — surfaced here
  //      via `channelLastActivity['#<gh>']`, the only persistent per-geohash D1
  //      signal the native store retains (see [kD1ActiveHeatFloor]).
  // All are still gated by activity-in-window below (the PWA's `recentCount < 1`
  // cut, channels.js:98), so seeding a silent geohash can't draw a phantom dot.
  final candidates = <String>{};

  // (1) seed geohashes (GL2).
  for (final g in kGlobeSeedGeohashes) {
    final gh = g.toLowerCase();
    if (isValidGeohash(gh) && gh != kDefaultChannel) candidates.add(gh);
  }

  // (2) registered geohash channels.
  for (final c in state.channels) {
    if (!c.isGeohash) continue;
    candidates.add(c.geohash.toLowerCase());
  }

  // (3) geohash-tagged channels with stored messages.
  state.messages.forEach((key, list) {
    if (!key.startsWith('#')) return;
    final name = key.substring(1).toLowerCase();
    if (!isValidGeohash(name) || name == kDefaultChannel) return;
    candidates.add(name);
  });

  // (4) geohashes with D1-reported last activity (GL1). `channelLastActivity`
  // is keyed `#<channel>`; only valid geohash keys are globe candidates.
  state.channelLastActivity.forEach((storageKey, _) {
    if (!storageKey.startsWith('#')) return;
    final name = storageKey.substring(1).toLowerCase();
    if (!isValidGeohash(name) || name == kDefaultChannel) return;
    candidates.add(name);
  });

  if (candidates.isEmpty) return const [];

  // Tally each candidate the PWA way (`updateGeohashChannels` +
  // `_combineGeohashActivity`, channels.js:84-125): bucket local messages into
  // 24 hourly slots, then sum `max(local[i], d1[i])` across the active window.
  final n = math.max(1, math.min(24, windowHours));
  for (final gh in candidates) {
    // (a) Bucket locally-stored messages into 24 hourly slots aligned with the
    // D1 buckets (index 0 = most recent hour). C05-4 — skip spam-gated messages
    // (`if (m._spamGated) continue;`, channels.js:88-89) so a geohash flooded
    // only by un-vouched strangers stays cold.
    final localBuckets = List<int>.filled(24, 0);
    final list = state.messages['#$gh'];
    if (list != null) {
      for (final m in list) {
        if (m.spamGated) continue;
        final ts = m.timestamp;
        if (ts <= 0) continue;
        var ageH = (nowMs - ts) ~/ (3600 * 1000);
        if (ageH < 0) ageH = 0;
        if (ageH < 24) localBuckets[ageH]++;
      }
    }
    // (b) Faithful per-hour combine: Σ_{i<n} max(local[i], d1[i]) over the
    // window, where d1[i] is the D1-reported count for that hour (channels.js
    // `_combineGeohashActivity`, :113-125).
    final d1Buckets = state.geohashD1Activity[gh];
    var total = 0;
    for (var i = 0; i < n; i++) {
      final local = localBuckets[i];
      final d1c =
          (d1Buckets != null && i < d1Buckets.length) ? d1Buckets[i] : 0;
      total += math.max(local, d1c);
    }
    // (c) Coverage fallback (no PWA analogue — its `_geohashD1Activity` always
    // carries buckets for a D1-active geohash): a geohash with a D1 last-activity
    // inside the window but no per-hour buckets still plots at the presence floor
    // rather than vanishing. Real buckets, when present, always win.
    if (total < 1 && (d1Buckets == null || d1Buckets.isEmpty)) {
      final d1LastMs = state.channelLastActivity['#$gh'] ?? 0;
      if (d1LastMs >= cutoffMs) total = kD1ActiveHeatFloor;
    }
    counts[gh] = total;
  }

  // GL5 — joined geohashes. The native store has no separate
  // `userJoinedChannels`: joining always registers the channel (`addChannel`)
  // and hydration loads persisted joined channels straight into `state.channels`
  // (app_state.dart `hydrateChannelState`). The one persisted set that can
  // diverge — and still implies the user keeps the channel — is `pinnedChannels`
  // (favorites, `nym_pinned_channels`). Union both so a joined/favorited geohash
  // that is only a candidate via D1/seed (not registered) still shows the green
  // "Go to Channel" dot, not the cyan "Join" dot. Mirrors the PWA's globe
  // `isJoined: userJoinedChannels.has(gh)` (geohash-globe.js:1166).
  final joined = <String>{
    for (final c in state.channels)
      if (c.isGeohash) c.geohash.toLowerCase(),
    for (final k in state.pinnedChannels)
      if (isValidGeohash(k)) k.toLowerCase(),
  };

  final out = <GeohashChannelPoint>[];
  counts.forEach((gh, n) {
    // PWA `updateGeohashChannels` (channels.js:98): `if (recentCount < 1) return;`
    // — only geohashes with ≥1 message inside the active window are plotted, so
    // registered-but-silent channels (n == 0) are NOT drawn as dots.
    if (n < 1) return;
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

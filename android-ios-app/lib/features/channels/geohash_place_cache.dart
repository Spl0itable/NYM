// Shared, persistent geohash → "City, Country" cache.
//
// Reverse geocoding goes to Nominatim, which caps clients at one request per
// second and explicitly forbids bulk lookups. That was tolerable when only the
// open channel's header resolved a place, but showing the location on every
// sidebar row multiplies lookups by the channel count, so two properties are
// load-bearing:
//
//   * it PERSISTS — a per-widget Map dies with the widget, and every relaunch
//     would re-geocode the whole sidebar;
//   * lookups are RATE-LIMITED, and concurrent callers for one geohash collapse
//     into a single request (the header and its sidebar row ask for the same
//     place on channel switch). Every lookup goes through our proxy, which
//     edge-caches Nominatim's answer for a day and is itself Nominatim's
//     client, so a few can be in flight at once — that is what lets a sidebar
//     of geohashes resolve in a round trip or two rather than one per second.
//
// Storage key and JSON shape match the web client's `nym_geohash_places`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

import '../../features/globe/geo_projection.dart' show geohashBounds;
import '../../features/globe/topojson.dart'
    show GeoFeature, decodeWorldTopoJson, describeRegion, kWorldTopoAsset;
import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';

/// Bound on the persisted map. Entries are ~30 bytes.
const int kGeohashPlaceMax = 500;

/// Lookups allowed in flight at once. Bounded because the proxy fans out to
/// Nominatim on a cache miss; generous because the cache absorbs the repeats.
const int kGeohashPlaceConcurrency = 4;

const String kGeohashPlaceKey = 'nym_geohash_places';

/// How many points inside a cell one lookup ATTEMPT may ask about: the centre,
/// then the four quarter-points. See `_probePoints` for why more than one is
/// needed. An attempt stops at the first point that answers, so a land-centred
/// geohash still costs a single request; this is the ceiling, not the cost.
const int kGeohashPlaceProbes = 5;

/// A geocode with no city/country is usually transient (rate limit, partial
/// response) but is sometimes real — a mid-ocean cell has no name. So a miss is
/// retried with backoff a few times and only then accepted. Caching the literal
/// "Unknown location" is what left a row stuck on it across restarts.
const Duration kGeohashPlaceRetryBase = Duration(seconds: 45);
const Duration kGeohashPlaceRetryMax = Duration(minutes: 30);
const int kGeohashPlaceMaxAttempts = 4;

/// Written by earlier builds; dropped on load so those rows can resolve again.
const String kGeohashPlacePoison = 'Unknown location';

class GeohashPlaceCache {
  GeohashPlaceCache({required KeyValueStore kv, required ApiClient api})
      : _kv = kv,
        _api = api {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  final Map<String, String> _cache = {};
  final Map<String, Future<String>> _inflight = {};
  final Map<String, ({DateTime at, int attempts})> _misses = {};

  int _active = 0;
  final List<Completer<void>> _waiters = [];
  Timer? _saveTimer;

  void _load() {
    try {
      final raw = _kv.getString(kGeohashPlaceKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (v is! String || v.isEmpty) return;
          if (v == kGeohashPlacePoison) return;
          _cache['$k'] = v;
        });
      }
    } catch (_) {
      // Corrupt or unavailable — start empty rather than fail construction.
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      try {
        var entries = _cache.entries.toList();
        if (entries.length > kGeohashPlaceMax) {
          // Keep the most recently resolved; Dart maps preserve insertion order.
          entries = entries.sublist(entries.length - kGeohashPlaceMax);
          _cache
            ..clear()
            ..addEntries(entries);
        }
        _kv.setString(kGeohashPlaceKey, jsonEncode(Map.fromEntries(entries)));
      } catch (_) {
        // Storage unavailable — the cache stays in memory for this session.
      }
    });
  }

  /// The resolved place, or null when this geohash has never been looked up.
  /// Callers render [geohashLocationLabel] (decoded locally, no network) until
  /// this returns something.
  String? cached(String geohash) => _cache[geohash.toLowerCase()];

  /// The bundled Natural Earth country polygons, decoded once and kept.
  ///
  /// Loaded lazily — only once a lookup has actually failed — so a session that
  /// never hits an unnamed cell never pays for it. Decoded on a background
  /// isolate, like the globe does.
  Future<List<GeoFeature>>? _worldFeatures;

  Future<List<GeoFeature>> _loadWorldFeatures() {
    return _worldFeatures ??= () async {
      try {
        final jsonStr = await rootBundle.loadString(kWorldTopoAsset);
        return await compute(decodeWorldTopoJson, jsonStr);
      } catch (_) {
        return const <GeoFeature>[];
      }
    }();
  }

  /// What to show when the geocoder can name nothing in a cell.
  ///
  /// Some cells genuinely have no address: `12` is the Antarctic plateau,
  /// `zxnjj` is open Arctic Ocean. Falling back to raw coordinates told the
  /// user nothing they could read. This answers from the map data the app
  /// already ships — the same countries file the globe draws — so it needs no
  /// network and cannot fail on somebody else's outage.
  ///
  /// Deliberately NOT written into [_cache]: it is a display fallback, not a
  /// resolved place, and caching it would end the search for a real name
  /// exactly the way caching "Unknown location" once did.
  Future<String> describeRegionFor(String geohash) async {
    final b = geohashBounds(geohash.toLowerCase());
    if (b == null) return '';
    try {
      final feats = await _loadWorldFeatures();
      if (feats.isEmpty) return '';
      return describeRegion(
        feats,
        (b.latLo + b.latHi) / 2,
        (b.lngLo + b.lngHi) / 2,
      );
    } catch (_) {
      return '';
    }
  }

  /// When a missed [geohash] may be looked up again. `null` once the attempt
  /// cap is reached, meaning the cell is accepted as having no name.
  DateTime? retryAt(String geohash) {
    final miss = _misses[geohash.toLowerCase()];
    if (miss == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (miss.attempts >= kGeohashPlaceMaxAttempts) return null;
    var backoff = kGeohashPlaceRetryBase * pow3(miss.attempts - 1);
    if (backoff > kGeohashPlaceRetryMax) backoff = kGeohashPlaceRetryMax;
    return miss.at.add(backoff);
  }

  static int pow3(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 3;
    }
    return v;
  }

  /// True when a lookup for [geohash] is worth making now.
  bool shouldRetry(String geohash, {bool force = false}) {
    final key = geohash.toLowerCase();
    if (_cache.containsKey(key)) return false;
    final at = retryAt(key);
    if (at == null) return force;
    return force || !DateTime.now().isBefore(at);
  }

  /// Resolves [geohash] to "City, Country" under the concurrency bound.
  /// Returns '' when the lookup missed; the caller keeps showing the decoded
  /// coordinates and a later call retries.
  Future<String> resolve(String geohash, {bool force = false}) {
    final key = geohash.toLowerCase();
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    if (!isValidGeohash(key)) return Future.value('');
    final pending = _inflight[key];
    if (pending != null) return pending;
    // force bypasses the timing gate but keeps the attempt history, so a
    // genuinely unnamed cell doesn't reset its counter on every app resume.
    if (!shouldRetry(key, force: force)) return Future.value('');

    final future = _run(key);
    _inflight[key] = future;
    return future;
  }

  void _noteMiss(String key) {
    final prev = _misses[key];
    _misses[key] =
        (at: DateTime.now(), attempts: (prev?.attempts ?? 0) + 1);
  }

  Future<String> _run(String key) async {
    if (_active >= kGeohashPlaceConcurrency) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      String place = '';
      for (final pt in _probePoints(key)) {
        final data = await _api.geocode(pt.lat, pt.lng, zoom: pt.zoom);
        place = _placeFromAddress(data);
        if (place.isNotEmpty) break;
      }
      if (place.isEmpty) {
        // A non-answer, not a place. Recording it as one is what pinned a row
        // to "Unknown location" permanently.
        _noteMiss(key);
        return '';
      }
      _cache[key] = place;
      _misses.remove(key);
      _scheduleSave();
      return place;
    } catch (_) {
      // A hard failure earns a retry too, rather than nothing to trigger one.
      _noteMiss(key);
      return '';
    } finally {
      _active--;
      _inflight.remove(key);
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }

  /// How precise a question to ask about a cell.
  ///
  /// Nominatim's `zoom` selects the granularity of the answer (3 country,
  /// 5 state, 8 county, 10 city). Asking a CITY-level question about a cell
  /// 1250 km across is a category error: a 2-character geohash covers whole
  /// countries, so the useful answer is the country.
  static int _zoomFor(String geohash) {
    final n = geohash.length;
    if (n <= 2) return 5; // ~1250km — state/country
    if (n <= 4) return 8; // ~40km — county
    return 10; // ~5km and finer — city
  }

  /// Points to ask about, in order: the centre, then the cell's four
  /// quarter-points.
  ///
  /// This is what makes short geohashes resolvable at all. A cell's centre very
  /// often falls in WATER even when the cell is mostly land — `gc` spans
  /// Ireland and part of Britain but centres on the Irish Sea, `dh` centres in
  /// the Gulf of Mexico, `9e` in the Pacific. Reverse geocoding open water
  /// returns no city and no country, which reads as a miss, so those rows sat
  /// on raw coordinates however many times the backoff retried — every retry
  /// asked the same unanswerable point.
  ///
  /// Only walked until something answers, so a land-centred geohash still costs
  /// exactly one request.
  static List<({double lat, double lng, int zoom})> _probePoints(
      String geohash) {
    final zoom = _zoomFor(geohash);
    final b = geohashBounds(geohash);
    if (b == null) return const [];
    ({double lat, double lng, int zoom}) at(double fx, double fy) => (
          lat: b.latLo + (b.latHi - b.latLo) * fy,
          lng: b.lngLo + (b.lngHi - b.lngLo) * fx,
          zoom: zoom,
        );
    final points = [
      at(0.5, 0.5),
      at(0.25, 0.25),
      at(0.75, 0.25),
      at(0.25, 0.75),
      at(0.75, 0.75),
    ];
    assert(points.length == kGeohashPlaceProbes);
    return points;
  }

  /// "City, Country" out of a reverse-geocode response, or '' when the point
  /// has no name. Falls back to the state/region when there is no city-level
  /// feature — the normal shape of a coarse-zoom answer for a large cell.
  static String _placeFromAddress(Map<String, dynamic> data) {
    final addr = (data['address'] as Map?) ?? const {};
    String s(Object? v) => v is String ? v : '';
    final city = [
      s(addr['city']),
      s(addr['town']),
      s(addr['village']),
      s(addr['county']),
      s(addr['state']),
      s(addr['region']),
      s(addr['territory']),
    ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
    final country = s(addr['country']);
    return [city, country].where((x) => x.isNotEmpty).join(', ');
  }
}

final geohashPlaceCacheProvider = Provider<GeohashPlaceCache>((ref) {
  return GeohashPlaceCache(
    kv: ref.read(keyValueStoreProvider),
    api: ApiClient(),
  );
});

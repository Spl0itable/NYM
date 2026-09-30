// Persistent geohash -> "City, Country" cache, rate-limited and deduped per Nominatim's usage policy.

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

/// Bound on the persisted map; entries are ~30 bytes.
const int kGeohashPlaceMax = 500;

/// Lookups in flight at once; bounded because proxy cache misses fan out to Nominatim.
const int kGeohashPlaceConcurrency = 4;

const String kGeohashPlaceKey = 'nym_geohash_places';

/// Max points probed per attempt (center, then quarter-points); stops at the first answer.
const int kGeohashPlaceProbes = 5;

/// Misses are retried with backoff a few times before being accepted as unnamed.
const Duration kGeohashPlaceRetryBase = Duration(seconds: 45);
const Duration kGeohashPlaceRetryMax = Duration(minutes: 30);
const int kGeohashPlaceMaxAttempts = 4;

/// Poison value from earlier builds, dropped on load so those rows resolve again.
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
      // Corrupt or unavailable: start empty rather than fail construction.
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
        // Storage unavailable: keep the cache in memory for this session.
      }
    });
  }

  /// Resolved place, or null if never looked up; callers show the local coordinate label until then.
  String? cached(String geohash) => _cache[geohash.toLowerCase()];

  /// Bundled country polygons, decoded lazily on an isolate only after a lookup fails.
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

  /// Offline description from shipped map data for cells with no address; never cached, so a real name is still sought.
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

  /// When a missed [geohash] may be retried; null once the attempt cap accepts it as unnamed.
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

  bool shouldRetry(String geohash, {bool force = false}) {
    final key = geohash.toLowerCase();
    if (_cache.containsKey(key)) return false;
    final at = retryAt(key);
    if (at == null) return force;
    return force || !DateTime.now().isBefore(at);
  }

  /// Resolves "City, Country" under the concurrency bound; '' on a miss, which a later call retries.
  Future<String> resolve(String geohash, {bool force = false}) {
    final key = geohash.toLowerCase();
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    if (!isValidGeohash(key)) return Future.value('');
    final pending = _inflight[key];
    if (pending != null) return pending;
    // force bypasses timing but keeps attempt history, so unnamed cells don't reset on every resume.
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
        // A non-answer, not a place.
        _noteMiss(key);
        return '';
      }
      _cache[key] = place;
      _misses.remove(key);
      _scheduleSave();
      return place;
    } catch (_) {
      // A hard failure earns a retry too.
      _noteMiss(key);
      return '';
    } finally {
      _active--;
      _inflight.remove(key);
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }

  /// Nominatim `zoom` granularity for a cell (3 country, 5 state, 8 county, 10 city).
  static int _zoomFor(String geohash) {
    final n = geohash.length;
    if (n <= 2) return 5; // ~1250km — state/country
    if (n <= 4) return 8; // ~40km — county
    return 10; // ~5km and finer — city
  }

  /// Center, then quarter-points: a cell's center often falls in water even when the cell is mostly land.
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

  /// "City, Country" from a reverse-geocode response, falling back to state; '' when unnamed.
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

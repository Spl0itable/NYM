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
          if (v is String && v.isNotEmpty) _cache['$k'] = v;
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

  /// Resolves [geohash] to "City, Country" under the concurrency bound.
  Future<String> resolve(String geohash) {
    final key = geohash.toLowerCase();
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    if (!isValidGeohash(key)) return Future.value('');
    final pending = _inflight[key];
    if (pending != null) return pending;

    final future = _run(key);
    _inflight[key] = future;
    return future;
  }

  Future<String> _run(String key) async {
    if (_active >= kGeohashPlaceConcurrency) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      final coords = decodeGeohash(key);
      final data = await _api.geocode(coords.lat, coords.lng, zoom: 10);
      final addr = (data['address'] as Map?) ?? const {};
      String s(Object? v) => v is String ? v : '';
      final city = [
        s(addr['city']),
        s(addr['town']),
        s(addr['village']),
        s(addr['county']),
      ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
      final country = s(addr['country']);
      var place = [city, country].where((x) => x.isNotEmpty).join(', ');
      if (place.isEmpty) place = 'Unknown location';
      _cache[key] = place;
      _scheduleSave();
      return place;
    } catch (_) {
      // Report the miss without caching it, so it retries later.
      return '';
    } finally {
      _active--;
      _inflight.remove(key);
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

final geohashPlaceCacheProvider = Provider<GeohashPlaceCache>((ref) {
  return GeohashPlaceCache(
    kv: ref.read(keyValueStoreProvider),
    api: ApiClient(),
  );
});

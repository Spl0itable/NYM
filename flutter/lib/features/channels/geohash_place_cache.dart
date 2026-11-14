// Persistent geohash -> "City, Country" cache, rate-limited and deduped per Nominatim's usage policy.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;

import '../../features/globe/geo_projection.dart' show geohashBounds;
import '../../features/globe/topojson.dart'
    show
        GeoFeature,
        countryAt,
        decodeWorldTopoJson,
        describeRegion,
        kWorldTopoAsset;
import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import '../../core/utils/isolate_gate.dart';

/// Bound on the persisted map; entries are under 100 bytes.
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

const Duration kGeohashPlaceSettled = Duration(days: 30);

const Duration kGeohashPlaceTouch = Duration(hours: 1);

/// Poison value from earlier builds, dropped on load so those rows resolve again.
const String kGeohashPlacePoison = 'Unknown location';

class _PlaceEntry {
  _PlaceEntry.place(String this.place, this.used)
      : label = '',
        attempts = 0,
        at = 0;
  _PlaceEntry.miss(this.label, this.attempts, this.at, this.used)
      : place = null;

  final String? place;
  final String label;
  final int attempts;
  final int at;
  int used;

  bool get settled => place == null && attempts >= kGeohashPlaceMaxAttempts;

  Map<String, Object> toJson() => place != null
      ? {'p': place!, 'u': used}
      : {'l': label, 'n': attempts, 't': at, 'u': used};

  static _PlaceEntry? fromJson(Object? v, int order) {
    if (v is String) {
      return v.isEmpty || v == kGeohashPlacePoison
          ? null
          : _PlaceEntry.place(v, order);
    }
    if (v is! Map) return null;
    final u = v['u'];
    final used = u is num && u.isFinite ? u.floor() : order;
    final p = v['p'];
    if (p is String) {
      return p.isEmpty || p == kGeohashPlacePoison
          ? null
          : _PlaceEntry.place(p, used);
    }
    final n = v['n'];
    final t = v['t'];
    if (n is int && n > 0 && t is num && t.isFinite) {
      final l = v['l'];
      return _PlaceEntry.miss(l is String ? l : '',
          n > kGeohashPlaceMaxAttempts ? kGeohashPlaceMaxAttempts : n,
          t.floor(), used);
    }
    return null;
  }
}

typedef GeohashRegion = ({String label, bool water});

class GeohashPlaceCache {
  GeohashPlaceCache({
    required this._kv,
    required this._api,
    DateTime Function()? now,
    Future<GeohashRegion> Function(String geohash)? region,
  })  : _now = now ?? DateTime.now,
        _regionOverride = region {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;
  final DateTime Function() _now;
  final Future<GeohashRegion> Function(String geohash)? _regionOverride;

  final Map<String, _PlaceEntry> _cache = {};
  final Map<String, Future<String>> _inflight = {};
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  final Map<String, ({int at, int attempts})> _failures = {};
  final Map<String, String> _regions = {};

  int _active = 0;
  final List<Completer<void>> _waiters = [];
  Timer? _saveTimer;

  int get _nowMs => _now().millisecondsSinceEpoch;

  void _load() {
    try {
      final raw = _kv.getString(kGeohashPlaceKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        var order = 0;
        decoded.forEach((k, v) {
          final e = _PlaceEntry.fromJson(v, order++);
          if (e != null) _cache['$k'] = e;
        });
      }
    } catch (_) {
      // Corrupt or unavailable: start empty rather than fail construction.
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), persistNow);
  }

  void persistNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final drop = _cache.length - kGeohashPlaceMax;
      if (drop > 0) {
        final byUse = _cache.entries.toList()
          ..sort((a, b) {
            final c = a.value.used.compareTo(b.value.used);
            return c != 0 ? c : a.key.compareTo(b.key);
          });
        for (final e in byUse.take(drop)) {
          _cache.remove(e.key);
        }
      }
      _kv.setString(
        kGeohashPlaceKey,
        jsonEncode({for (final e in _cache.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // Storage unavailable: keep the cache in memory for this session.
    }
  }

  _PlaceEntry? _touch(String key) {
    final e = _cache[key];
    if (e == null) return null;
    final now = _nowMs;
    if (!(now - e.used < kGeohashPlaceTouch.inMilliseconds)) {
      e.used = now;
      _scheduleSave();
    }
    return e;
  }

  ({String? place, String label, bool settled})? known(String geohash) {
    final e = _touch(geohash.toLowerCase());
    if (e == null) return null;
    return (place: e.place, label: e.label, settled: e.settled);
  }

  /// Resolved place, or null if never named.
  String? cached(String geohash) => known(geohash)?.place;

  String? missLabel(String geohash) {
    final k = known(geohash);
    return k == null || k.place != null ? null : k.label;
  }

  String? nameFor(String geohash) {
    final key = geohash.toLowerCase();
    final k = known(key);
    final place = k?.place;
    if (place != null) return place;
    if (k != null && k.label.isNotEmpty) return k.label;
    return _regions[key];
  }

  /// Bundled country polygons, decoded lazily on an isolate only after a lookup fails.
  Future<List<GeoFeature>>? _worldFeatures;

  Future<List<GeoFeature>> _loadWorldFeatures() {
    return _worldFeatures ??= () async {
      try {
        final jsonStr = await rootBundle.loadString(kWorldTopoAsset);
        return await gatedCompute(decodeWorldTopoJson, jsonStr);
      } catch (_) {
        return const <GeoFeature>[];
      }
    }();
  }

  Future<GeohashRegion> _regionOf(String geohash) async {
    final override = _regionOverride;
    if (override != null) return override(geohash);
    final b = geohashBounds(geohash);
    if (b == null) return (label: '', water: false);
    try {
      final feats = await _loadWorldFeatures();
      if (feats.isEmpty) return (label: '', water: false);
      final lat = (b.latLo + b.latHi) / 2;
      final lng = (b.lngLo + b.lngHi) / 2;
      final label = describeRegion(feats, lat, lng);
      return (
        label: label,
        water: label.isNotEmpty &&
            lat > -85.5 &&
            countryAt(feats, lat, lng).isEmpty,
      );
    } catch (_) {
      return (label: '', water: false);
    }
  }

  /// Offline description from shipped map data for cells with no address, kept with the cell's miss.
  Future<String> describeRegionFor(String geohash) async {
    final key = geohash.toLowerCase();
    final e = _cache[key];
    if (e != null && e.place == null && e.label.isNotEmpty) return e.label;
    final label = (await _regionOf(key)).label;
    if (label.isNotEmpty && _regions[key] != label) {
      _regions.remove(key);
      if (_regions.length >= kGeohashPlaceMax) {
        _regions.remove(_regions.keys.first);
      }
      _regions[key] = label;
      changes.value++;
    }
    return label;
  }

  static int _backoffMs(int attempts) {
    final ms = kGeohashPlaceRetryBase.inMilliseconds *
        pow3(attempts < 1 ? 0 : attempts - 1);
    final cap = kGeohashPlaceRetryMax.inMilliseconds;
    return ms > cap ? cap : ms;
  }

  /// When a missed [geohash] may be retried in this session; null once it is settled or out of attempts.
  DateTime? retryAt(String geohash) {
    final key = geohash.toLowerCase();
    final e = _cache[key];
    final f = _failures[key];
    var at = 0;
    if (e != null && e.place == null) {
      if (e.settled) return null;
      at = e.at + _backoffMs(e.attempts);
    }
    if (f != null) {
      if (f.attempts >= kGeohashPlaceMaxAttempts) return null;
      final due = f.at + _backoffMs(f.attempts);
      if (due > at) at = due;
    }
    return DateTime.fromMillisecondsSinceEpoch(at);
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
    final e = _cache[key];
    if (e != null && e.place != null) return false;
    final now = _nowMs;
    if (e != null && e.settled) {
      if (now < e.at + kGeohashPlaceSettled.inMilliseconds) return false;
    } else if (e != null && !force && now < e.at + _backoffMs(e.attempts)) {
      return false;
    }
    final f = _failures[key];
    if (f != null &&
        !force &&
        (f.attempts >= kGeohashPlaceMaxAttempts ||
            now < f.at + _backoffMs(f.attempts))) {
      return false;
    }
    return true;
  }

  void noteAnswer(String geohash, String place) {
    final key = geohash.toLowerCase();
    _cache.remove(key);
    _cache[key] = _PlaceEntry.place(place, _nowMs);
    _failures.remove(key);
    _scheduleSave();
    changes.value++;
  }

  void noteNoName(String geohash, String label, {required bool water}) {
    final key = geohash.toLowerCase();
    final prev = _cache[key];
    final miss = prev != null && prev.place == null ? prev : null;
    final int n;
    if (water || (miss != null && miss.settled)) {
      n = kGeohashPlaceMaxAttempts;
    } else {
      final next = (miss?.attempts ?? 0) + 1;
      n = next > kGeohashPlaceMaxAttempts ? kGeohashPlaceMaxAttempts : next;
    }
    final now = _nowMs;
    _cache.remove(key);
    _cache[key] = _PlaceEntry.miss(
        label.isNotEmpty ? label : (miss?.label ?? ''), n, now, now);
    _failures.remove(key);
    _scheduleSave();
    changes.value++;
  }

  void noteFailure(String geohash) {
    final key = geohash.toLowerCase();
    final prev = _failures[key];
    _failures[key] = (at: _nowMs, attempts: (prev?.attempts ?? 0) + 1);
  }

  /// Resolves "City, Country" under the concurrency bound; '' on a miss, which a later call may retry.
  Future<String> resolve(String geohash, {bool force = false}) {
    final key = geohash.toLowerCase();
    final hit = cached(key);
    if (hit != null) return Future.value(hit);
    if (!isValidGeohash(key)) return Future.value('');
    final pending = _inflight[key];
    if (pending != null) return pending;
    if (!shouldRetry(key, force: force)) return Future.value('');

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
      String place = '';
      for (final pt in _probePoints(key)) {
        final data = await _api.geocode(pt.lat, pt.lng, zoom: pt.zoom);
        place = _placeFromAddress(data);
        if (place.isNotEmpty) break;
      }
      if (place.isNotEmpty) {
        noteAnswer(key, place);
        return place;
      }
      final region = await _regionOf(key);
      noteNoName(key, region.label, water: region.water);
      return '';
    } catch (_) {
      noteFailure(key);
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

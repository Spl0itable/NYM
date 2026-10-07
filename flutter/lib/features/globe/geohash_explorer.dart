import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart' show LogicalKeyboardKey, rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_sheet.dart';
import '../channels/channel_share.dart';
import '../i18n/i18n.dart';
import '../toasts/toast_center.dart';
import 'explorer_controls.dart';
import 'explorer_lists.dart';
import 'explorer_peek.dart';
import 'explorer_search.dart';
import 'geo_detail.dart';
import 'geo_explore.dart';
import 'geo_map_painter.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'precision_path.dart';
import 'topojson.dart';
import '../../widgets/common/nym_tooltip.dart';

/// Below this width the explorer uses its phone layout.
const double kGlobeNarrowBreakpoint = 768;


const String kAdmin1Asset =
    'assets/data/ne_50m_admin_1_states_provinces_lakes.json';

const String kCitiesAsset = 'assets/data/ne_50m_populated_places_simple.json';

/// Zoom at which admin-1 and city layers lazy-load.
const double kSubregionZoomThreshold = 2.5;

const List<int> kActiveWindowOptions = kGeoWindowOptions;

/// Re-tally channel activity every 30s.
const Duration kActiveWindowRefresh = Duration(milliseconds: 30000);

/// Repaint the day/night terminator every 60s.
const Duration kDaynightRefresh = Duration(milliseconds: 60000);

const Duration kGeoFlyDuration = Duration(milliseconds: 650);

const Duration kGeoSelectPulse = Duration(milliseconds: 900);

const Duration kGeoAmbientPulse = Duration(milliseconds: 1600);

/// Isolate entry for [compute] decoding the world TopoJSON.
List<GeoFeature> decodeWorldFeaturesIsolate(String jsonString) =>
    decodeWorldTopoJson(jsonString);

/// Isolate entry for [compute] decoding the ~1.7 MB admin-1 GeoJSON.
List<GeoFeature> decodeAdmin1FeaturesIsolate(String jsonString) =>
    decodeAdmin1GeoJson(jsonString);

/// Isolate entry for [compute] decoding the cities GeoJSON.
List<CityPoint> decodeCitiesIsolate(String jsonString) =>
    decodeCitiesGeoJson(jsonString);

List<GeoPlace> buildGeoPlacesIsolate(List<String> src) => buildGeoPlaceIndex(
      cities: jsonDecode(src[0]),
      admin1: jsonDecode(src[1]),
      countries: decodeWorldTopoJson(src[2]),
    );

Future<List<GeoPlace>>? _bundledPlaces;

Future<List<GeoPlace>> loadBundledGeoPlaces() {
  final cached = _bundledPlaces;
  if (cached != null) return cached;
  final f = () async {
    final src = await Future.wait([
      rootBundle.loadString(kCitiesAsset),
      rootBundle.loadString(kAdmin1Asset),
      rootBundle.loadString(kWorldTopoAsset),
    ]);
    return compute(buildGeoPlacesIsolate, src);
  }();
  _bundledPlaces = f;
  f.catchError((Object _) {
    _bundledPlaces = null;
    return const <GeoPlace>[];
  });
  return f;
}

typedef GeoTierLoader = Future<GeoTierGeometry> Function(int tier);

final Map<int, Future<GeoTierGeometry>> _bundledTiers = {};

Future<GeoTierGeometry> loadBundledGeoTier(int tier) {
  final cached = _bundledTiers[tier];
  if (cached != null) return cached;
  final f = () async {
    final src = await rootBundle.loadString(kGeoTierAssets[tier], cache: false);
    return compute(decodeGeoTier, src);
  }();
  _bundledTiers[tier] = f;
  f.catchError((Object _) {
    _bundledTiers.remove(tier);
    return GeoTierGeometry(
      countries: GeoLayer.empty,
      lakes: GeoLayer.empty,
      rivers: GeoLayer.empty,
      countryLabels: const [],
    );
  });
  return f;
}

final geoTierLoaderProvider =
    Provider<GeoTierLoader>((ref) => loadBundledGeoTier);

final Expando<GeoTierPaths> _tierPathCache = Expando<GeoTierPaths>();

final geoPlacesLoaderProvider =
    Provider<Future<List<GeoPlace>> Function()>((ref) => loadBundledGeoPlaces);

/// Session-only globe preferences (toggles and window), since each open builds a new explorer; not persisted.
final globePrefsProvider =
    StateProvider<({bool heat, bool daynight, bool grid, int windowHours})>(
  (ref) => (heat: false, daynight: false, grid: false, windowHours: 24),
);

/// Equirectangular geohash channel map; Join pops the route with the lowercase geohash.
class GeohashExplorer extends ConsumerStatefulWidget {
  const GeohashExplorer({super.key, this.focusGeohash});

  /// Open zoomed to this cell with its info panel showing; null opens the world view.
  final String? focusGeohash;

  /// Non-opaque modal route floating over the app; resolves to the chosen geohash or null.
  static Route<String> route({String? focusGeohash}) {
    return PageRouteBuilder<String>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, _) {
        final page = GeohashExplorer(focusGeohash: focusGeohash);
        if (!useNymSheet(context)) return page;
        final nym = context.nym;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('geohashSheetBarrier'),
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: FadeTransition(
                  opacity: animation,
                  child: ColoredBox(
                    color: nym.isLight
                        ? const Color(0x4D000000)
                        : const Color(0x66000000),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                )),
                child: KeyboardInset(
                  child: NymSheetFrame(
                    dragAnywhere: false,
                    fullHeight: true,
                    child: page,
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionsBuilder: (context, animation, _, child) =>
          useNymSheet(context)
              ? child
              : FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  ConsumerState<GeohashExplorer> createState() => _GeohashExplorerState();
}

class _GeohashExplorerState extends ConsumerState<GeohashExplorer>
    with TickerProviderStateMixin {
  GeoView _view = const GeoView();
  List<GeoFeature> _features = const [];
  Size _lastSize = Size.zero;

  /// Whether [GeohashExplorer.focusGeohash] has been framed yet.
  bool _focusApplied = false;

  // Admin-1 and city layers load once past the zoom threshold; the loaded flags flip first to prevent double loads.
  List<GeoFeature> _admin1Features = const [];
  List<CityPoint> _cities = const [];
  bool _admin1Loaded = false;
  bool _citiesLoaded = false;

  List<GeoTierPaths?> _tierPaths = const [null, null, null];
  List<List<GeoLabelFeature>?> _tierLabels = const [null, null, null];
  final Set<int> _tierRequested = {};

  final GlobalKey _searchBoxKey = GlobalKey();
  final GlobalKey _controlsKey = GlobalKey();
  final GlobalKey _mapBoxKey = GlobalKey();
  List<Rect> _occupied = const [];

  bool _heatmap = false;
  bool _daynight = false;
  bool _grid = false;
  int _activeWindowHours = 24;

  String? _hoveredGeohash;
  bool _dragging = false;

  /// Selected channel or cell, driving the info panel and Join.
  GeohashChannelPoint? _selected;

  /// Reverse-geocoded "city, country" for [_selected].
  String _locationInfo = tr('Loading location...');

  /// Guards against a stale geocode overwriting a newer selection.
  int _geocodeToken = 0;

  // Cumulative pinch scale of the previous frame, used to derive a per-frame factor; reset on scale start.
  double _lastScale = 1.0;

  // Heatmap image built off the paint pass, since the accumulate-and-remap can't run inside paint.
  ui.Image? _heatImage;
  HeatmapInput? _heatInputForImage; // the input that produced _heatImage
  HeatmapInput? _heatInFlight; // the input currently being built
  Timer? _heatDebounce;

  final ApiClient _api = ApiClient();

  // Activity re-tally every 30s; terminator repaint every 60s only while day/night is on.
  Timer? _activeWindowTimer;
  Timer? _daynightTimer;
  final ValueNotifier<int> _ticker = ValueNotifier<int>(0);

  late final AnimationController _fly =
      AnimationController(vsync: this, duration: kGeoFlyDuration);
  late final AnimationController _selectPulse =
      AnimationController(vsync: this, duration: kGeoSelectPulse);
  late final AnimationController _ambient =
      AnimationController(vsync: this, duration: kGeoAmbientPulse);
  GeoView _flyFrom = const GeoView();
  GeoView _flyTo = const GeoView();
  bool _reduceMotion = false;

  bool _listsOpen = false;
  bool _layersOpen = false;
  final FocusNode _layersButtonFocus = FocusNode(debugLabel: 'geo-layers');
  GeoListTab _listTab = GeoListTab.active;
  List<GeoPlace> _places = const [];
  bool _placesRequested = false;
  final Map<String, String> _placeLabels = {};

  @override
  void initState() {
    super.initState();
    // Restore this session's toggles and active window.
    final prefs = ref.read(globePrefsProvider);
    _heatmap = prefs.heat;
    _daynight = prefs.daynight;
    _grid = prefs.grid;
    _activeWindowHours = normalizeGeoWindowHours(prefs.windowHours);
    _fly.addListener(_onFlyTick);
    _selectPulse.addStatusListener((s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        if (mounted) setState(() {});
      }
    });
    _loadFeatures();
    // Pull recent D1 activity on open so unloaded channels still show; throttled in the controller.
    _refreshD1Activity();
    // Refresh D1 activity and rebuild so dots re-tally against the moving window.
    _activeWindowTimer = Timer.periodic(kActiveWindowRefresh, (_) {
      if (!mounted) return;
      _refreshD1Activity();
      _ticker.value++;
      setState(() {}); // re-run _channels() against the new "now".
    });
    // Repaint only when the terminator is shown.
    _daynightTimer = Timer.periodic(kDaynightRefresh, (_) {
      if (mounted && _daynight) _ticker.value++;
    });
  }

  /// Throttled (~30s) D1 activity refresh folded into `channelLastActivity`; safe to call often.
  void _refreshD1Activity() {
    unawaited(ref.read(nostrControllerProvider).refreshGeohashActivity());
  }

  @override
  void dispose() {
    _activeWindowTimer?.cancel();
    _daynightTimer?.cancel();
    _heatDebounce?.cancel();
    _heatImage?.dispose();
    _ticker.dispose();
    _fly.dispose();
    _selectPulse.dispose();
    _ambient.dispose();
    _layersButtonFocus.dispose();
    super.dispose();
  }

  Future<void> _loadFeatures() async {
    try {
      final jsonStr = await rootBundle.loadString(kWorldTopoAsset);
      // Decode off the UI thread.
      final feats = await compute(decodeWorldFeaturesIsolate, jsonStr);
      await prewarmGeoPaths(feats);
      if (!mounted) return;
      setState(() => _features = feats);
    } catch (_) {
      // Decoding failed: leave an empty map.
    }
  }

  /// Loads admin-1 and city data once each past the zoom threshold, decoded off the UI thread; call after any zoom change.
  void _measureOccupied() {
    if (!mounted) return;
    final map = _mapBoxKey.currentContext?.findRenderObject();
    if (map is! RenderBox || !map.hasSize) return;
    final out = <Rect>[];
    for (final k in [_searchBoxKey, _controlsKey]) {
      final b = k.currentContext?.findRenderObject();
      if (b is! RenderBox || !b.hasSize || !b.attached) continue;
      out.add(map.globalToLocal(b.localToGlobal(Offset.zero)) & b.size);
    }
    if (!listEquals(out, _occupied)) setState(() => _occupied = out);
  }

  void _ensureTier() {
    if (_lastSize.isEmpty) return;
    final want = geoTierFor(_view.scale(_lastSize));
    if (want < 1 || _tierRequested.contains(want)) return;
    _tierRequested.add(want);
    _loadTier(want);
  }

  Future<void> _loadTier(int tier) async {
    try {
      final g = await ref.read(geoTierLoaderProvider)(tier);
      final paths = _tierPathCache[g] ?? await buildGeoTierPaths(g);
      _tierPathCache[g] ??= paths;
      if (!mounted) return;
      setState(() {
        _tierPaths = [..._tierPaths]..[tier] = paths;
        _tierLabels = [..._tierLabels]..[tier] = g.countryLabels;
      });
    } catch (_) {
      _tierRequested.remove(tier);
    }
  }

  void _ensureSubregions({bool force = false}) {
    _ensureTier();
    final want = force || _view.zoom >= kSubregionZoomThreshold;
    if (want && !_admin1Loaded) {
      _admin1Loaded = true;
      _loadAdmin1();
    }
    if (want && !_citiesLoaded) {
      _citiesLoaded = true;
      _loadCities();
    }
  }

  Future<void> _loadAdmin1() async {
    try {
      final jsonStr = await rootBundle.loadString(kAdmin1Asset);
      final feats = await compute(decodeAdmin1FeaturesIsolate, jsonStr);
      await prewarmGeoPaths(feats, closed: false);
      if (!mounted) return;
      setState(() => _admin1Features = feats);
    } catch (_) {
      // Decoding failed: allow a retry.
      _admin1Loaded = false;
    }
  }

  Future<void> _loadCities() async {
    try {
      final jsonStr = await rootBundle.loadString(kCitiesAsset);
      final cities = await compute(decodeCitiesIsolate, jsonStr);
      if (!mounted) return;
      setState(() => _cities = cities);
    } catch (_) {
      // Decoding failed: allow a retry.
      _citiesLoaded = false;
    }
  }

  Future<List<GeoPlace>> _loadPlaces() {
    _ensureSubregions(force: true);
    final f = ref.read(geoPlacesLoaderProvider)();
    if (!_placesRequested) {
      _placesRequested = true;
      f.then((p) {
        if (!mounted) return;
        setState(() {
          _places = p;
          _placeLabels.clear();
        });
      }, onError: (_) {
        _placesRequested = false;
      });
    }
    return f;
  }

  List<GeohashChannelPoint> _channels() {
    final state = ref.read(appStateProvider);
    return buildGeohashChannels(state, windowHours: _activeWindowHours);
  }

  /// Changes the window and forces an immediate redraw; no D1 refetch.
  void _setActiveWindow(int hours) {
    final h = normalizeGeoWindowHours(hours);
    if (h == _activeWindowHours) return;
    setState(() => _activeWindowHours = h);
    _savePrefs();
    _ticker.value++;
  }

  /// Snapshot preferences so a later reopen restores them.
  void _savePrefs() {
    ref.read(globePrefsProvider.notifier).state = (
      heat: _heatmap,
      daynight: _daynight,
      grid: _grid,
      windowHours: _activeWindowHours,
    );
  }

  /// User location, only when proximity sort is on and a location is known.
  ({double lat, double lng})? _userLocation() {
    final sortByProximity = ref.read(settingsProvider).sortByProximity;
    final loc = ref.read(userLocationProvider);
    if (!sortByProximity || loc == null) return null;
    return (lat: loc.lat, lng: loc.lng);
  }

  void _setView(GeoView v, Size size) {
    if (_fly.isAnimating) _fly.stop();
    setState(() => _view = v.clamped(size));
    // Trigger the lazy detail load on any zoom change.
    _ensureSubregions();
  }

  void _onFlyTick() {
    final t = Curves.easeInOutCubic.transform(_fly.value);
    setState(() => _view = GeoView.lerp(_flyFrom, _flyTo, t).clamped(_lastSize));
    if (_fly.isCompleted) _ensureSubregions();
  }

  void _flyToView(GeoView target, Size size) {
    final to = target.clamped(size);
    if (_reduceMotion) {
      if (_fly.isAnimating) _fly.stop();
      setState(() => _view = to);
      _ensureSubregions();
      return;
    }
    _flyFrom = _view;
    _flyTo = to;
    _fly.forward(from: 0);
  }

  void _startSelectPulse() {
    if (_reduceMotion) return;
    _selectPulse.repeat(count: 2);
  }

  /// Rebuilds the heatmap image when inputs change; clears it when heatmap is off.
  void _maybeRebuildHeat(
      Size size, List<GeohashChannelPoint> channels, double dpr) {
    if (!_heatmap) {
      if (_heatImage != null || _heatInputForImage != null) {
        _heatImage?.dispose();
        _heatImage = null;
        _heatInputForImage = null;
      }
      _heatDebounce?.cancel();
      _heatInFlight = null;
      return;
    }
    final input = HeatmapInput(
      view: _view,
      size: size,
      dpr: dpr,
      points: [
        for (final c in channels)
          (lng: c.lng, lat: c.lat, messages: c.messages),
      ],
    );
    // Already current or already building this input.
    if (input == _heatInputForImage || input == _heatInFlight) return;
    _heatDebounce?.cancel();
    _heatDebounce = Timer(const Duration(milliseconds: 60), () {
      if (!mounted || !_heatmap) return;
      _heatInFlight = input;
      buildHeatmapImage(input).then((img) {
        if (!mounted || !_heatmap) {
          img?.dispose();
          return;
        }
        // Drop the result if the inputs moved on meanwhile.
        if (_heatInFlight != input) {
          img?.dispose();
          return;
        }
        setState(() {
          _heatImage?.dispose();
          _heatImage = img;
          _heatInputForImage = input;
          _heatInFlight = null;
        });
      });
    });
  }

  List<GeoCluster> _clusters(Size size, List<GeohashChannelPoint> channels) {
    if (_heatmap || _view.zoom >= kGeoClusterMaxZoom) return const [];
    return clusterGeoPoints([
      for (final c in channels)
        () {
          final p = _view.project(c.lng, c.lat, size);
          return GeoClusterPoint(
              id: c.geohash, x: p.dx, y: p.dy, messages: c.messages);
        }(),
    ], kGeoClusterCellPx.toDouble());
  }

  GeoCluster? _clusterAt(Offset local, Size size) {
    for (final k in _clusters(size, _channels())) {
      if (k.count < 2) continue;
      if ((Offset(k.x, k.y) - local).distance <= 22) return k;
    }
    return null;
  }

  GeohashChannelPoint? _channelAt(Offset local, Size size) {
    const hitR = 10.0;
    GeohashChannelPoint? nearest;
    var best = double.infinity;
    for (final ch in _channels()) {
      final p = _view.project(ch.lng, ch.lat, size);
      final d = (p - local).distance;
      if (d < hitR && d < best) {
        best = d;
        nearest = ch;
      }
    }
    return nearest;
  }

  void _onTapUp(TapUpDetails d, Size size) {
    if (_layersOpen) {
      setState(() => _layersOpen = false);
      return;
    }
    final local = d.localPosition;
    final cluster = _clusterAt(local, size);
    if (cluster != null) {
      _flyToCluster(cluster, size);
      return;
    }
    final ch = _channelAt(local, size);
    if (ch != null) {
      // Tapping a dot selects without re-framing; only grid-cell taps zoom.
      _selectChannel(ch);
      return;
    }
    if (_grid) {
      final u = _view.unproject(local.dx, local.dy, size);
      if (u.lat < -90 || u.lat > 90 || u.lng < -180 || u.lng > 180) return;
      final precision = computeGridPrecision(_view, size);
      final gh = encodeGeohash(u.lat, u.lng, precision: precision);
      _focusCell(gh, size, fly: false, pulse: false);
    }
  }

  void _flyToCluster(GeoCluster k, Size size) {
    var latLo = 90.0, latHi = -90.0, lngLo = 180.0, lngHi = -180.0;
    for (final id in k.ids) {
      final b = geohashBounds(id);
      if (b == null) continue;
      latLo = math.min(latLo, b.latLo);
      latHi = math.max(latHi, b.latHi);
      lngLo = math.min(lngLo, b.lngLo);
      lngHi = math.max(lngHi, b.lngHi);
    }
    if (latLo > latHi) return;
    final fit = _view.fitBounds(
        (latLo: latLo, latHi: latHi, lngLo: lngLo, lngHi: lngHi), size,
        padding: 0.5);
    final target = fit.zoom <= _view.zoom
        ? fit.copyWith(zoom: math.min(GeoView.maxZoom, kGeoClusterMaxZoom + 0.5))
        : fit;
    _flyToView(target, size);
  }

  /// Selects for the info panel and starts a reverse geocode for its Location row.
  void _selectChannel(GeohashChannelPoint point) {
    final token = ++_geocodeToken;
    setState(() {
      _selected = point;
      _hoveredGeohash = point.geohash;
      _locationInfo = tr('Loading location...');
      _layersOpen = false;
    });
    _fetchLocation(point.lat, point.lng, token);
  }

  /// Updates the Location row only if [token] is still current.
  Future<void> _fetchLocation(double lat, double lng, int token) async {
    String result;
    try {
      final data = await _api.geocode(lat, lng, zoom: 10);
      final addr = (data['address'] as Map?) ?? const {};
      String s(Object? v) => v is String ? v : '';
      final city = [
        s(addr['city']),
        s(addr['town']),
        s(addr['village']),
        s(addr['county']),
      ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
      final country = s(addr['country']);
      result = [city, country].where((x) => x.isNotEmpty).join(', ');
      if (result.isEmpty) result = tr('Unknown location');
    } catch (_) {
      result = tr('Unknown');
    }
    if (!mounted || token != _geocodeToken) return;
    setState(() => _locationInfo = result);
  }

  void _focusCell(String geohash, Size size,
      {bool fly = true, bool pulse = true}) {
    final gh = geohash.toLowerCase();
    final bounds = geohashBounds(gh);
    if (bounds == null) return;
    final existing = _channels().where((c) => c.geohash == gh);
    final joined = ref.read(appStateProvider).channels.any((c) => c.key == gh);
    final point = existing.isNotEmpty
        ? existing.first
        : GeohashChannelPoint(
            geohash: gh,
            lat: (bounds.latLo + bounds.latHi) / 2,
            lng: (bounds.lngLo + bounds.lngHi) / 2,
            messages: 0,
            isJoined: joined,
          );
    _selectChannel(point);
    final narrow = size.width < kGlobeNarrowBreakpoint;
    var target = _view.fitBounds(bounds, size, padding: narrow ? 0.45 : 0.7);
    if (narrow) {
      target = target.copyWith(
          cy: target.cy - 0.23 * size.height / target.scale(size));
    }
    if (fly) {
      _flyToView(target, size);
    } else {
      if (_fly.isAnimating) _fly.stop();
      _setView(target, size);
    }
    if (pulse) _startSelectPulse();
  }

  void _resetView(Size size) {
    if (_fly.isAnimating) _fly.stop();
    setState(() {
      _view = const GeoView().clamped(size);
      _heatmap = false;
      _daynight = false;
      _grid = false;
      _selected = null;
      _hoveredGeohash = null;
      _locationInfo = tr('Loading location...');
      _activeWindowHours = 24;
      _layersOpen = false;
    });
    // Reset also clears the session preferences.
    _savePrefs();
  }

  void _goToLocation(Size size) {
    final loc = _userLocation();
    if (loc == null) {
      showToast(tr('Location is off. Turn on "Sort by proximity" in Settings to use your location.'));
      return;
    }
    final b = geohashBounds(encodeGeoGeohash(loc.lat, loc.lng, 4));
    if (b == null) return;
    _flyToView(_view.fitBounds(b, size), size);
  }

  void _join(String geohash) {
    Navigator.of(context).pop(geohash.toLowerCase());
  }

  void _toggleSaved(String geohash) {
    ref.read(nostrControllerProvider).togglePin(geohash.toLowerCase());
    setState(() {});
  }

  Set<String> _savedSet() => {
        for (final k in ref.read(appStateProvider).pinnedChannels)
          if (k != kDefaultChannel && isGeoGeohash(k)) k.toLowerCase(),
      };

  String _placeLabel(String gh) {
    final hit = _placeLabels[gh];
    if (hit != null) return hit;
    var label = roomPlaceLabel(_places, gh);
    if (label.isEmpty && _features.isNotEmpty) {
      final b = geohashBounds(gh);
      if (b != null) {
        label = countryAt(
            _features, (b.latLo + b.latHi) / 2, (b.lngLo + b.lngHi) / 2);
      }
    }
    if (_places.isNotEmpty || _features.isNotEmpty) _placeLabels[gh] = label;
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final style = GeoMapStyle.resolve(
      isLight: nym.isLight,
      primary: nym.primary,
      warning: nym.warning,
    );

    if (NymSheetScope.of(context)) {
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Column(
              children: [
                NymSheetDragRegion(child: _header(nym)),
                Expanded(child: _body(style)),
              ],
            ),
            Positioned(
              top: 5,
              right: 8,
              child: _ModalCloseButton(
                nym: nym,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      );
    }

    // Centered overlay card over a mode-aware translucent scrim, the only dimming layer under a non-opaque route.
    return Scaffold(
      backgroundColor: nym.isLight
          ? const Color(0x4D000000)
          : const Color(0x66000000),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 800),
            child: FractionallySizedBox(
              widthFactor: 0.90,
              heightFactor: 0.90,
              child: Container(
                decoration: BoxDecoration(
                  color: nym.bgSecondary,
                  border: Border.all(color: nym.glassBorder),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: nym.isLight
                      ? const [
                          BoxShadow(
                            color: Color(0x1F000000),
                            blurRadius: 40,
                            offset: Offset(0, 8),
                          ),
                        ]
                      : [
                          const BoxShadow(
                            color: Color(0x80000000),
                            blurRadius: 32,
                            offset: Offset(0, 8),
                          ),
                          BoxShadow(color: nym.primaryA(0.1), blurRadius: 20),
                        ],
                ),
                clipBehavior: Clip.antiAlias,
                // The close chip floats over the card via a Stack.
                child: Stack(
                  children: [
                    Column(
                      children: [
                        _header(nym),
                        Expanded(child: _body(style)),
                      ],
                    ),
                    Positioned(
                      top: 5,
                      right: 8,
                      child: _ModalCloseButton(
                        nym: nym,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors nym) {
    return Container(
      // Right padding reserves room for the close chip; title left-aligned.
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 56, 16),
      decoration: BoxDecoration(
        color: const Color(0x26000000),
        border: Border(bottom: BorderSide(color: nym.glassBorder)),
      ),
      child: Text(
        tr('GEOHASH EXPLORER'),
        style: TextStyle(
          fontSize: 18,
          color: nym.primary,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _body(GeoMapStyle style) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _reduceMotion = MediaQuery.of(context).disableAnimations;
        if (_reduceMotion && (_fly.isAnimating || _selectPulse.isAnimating)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_fly.isAnimating) {
              _fly.stop();
              setState(() => _view = _flyTo.clamped(_lastSize));
            }
            if (_selectPulse.isAnimating) _selectPulse.stop();
          });
        }
        // Clamp the view on first layout or resize.
        if (size != _lastSize) {
          _lastSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _view = _view.clamped(size));
            // Frame the focus cell once, on the first real layout.
            final focus = widget.focusGeohash;
            if (!_focusApplied && focus != null && focus.isNotEmpty) {
              _focusApplied = true;
              _focusCell(focus, size, fly: false);
            }
          });
        }

        // Watch the store and location so dots, heatmap and the location row update live.
        ref.watch(appStateProvider);
        ref.watch(settingsProvider.select((s) => s.sortByProximity));
        ref.watch(userLocationProvider);
        final channels = _channels();

        // Keep the heatmap image in sync with the current inputs.
        final dpr = capGeoDpr(MediaQuery.devicePixelRatioOf(context));
        _maybeRebuildHeat(size, channels, dpr);

        WidgetsBinding.instance.addPostFrameCallback((_) => _measureOccupied());
        final narrow = size.width < kGlobeNarrowBreakpoint;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final recent = <String>{
          for (final c in channels)
            if (isGeoRecent(c.lastActivityMs, nowMs)) c.geohash,
        };
        _syncAmbient(recent.isNotEmpty && !_heatmap);
        final saved = _savedSet();
        final inset = narrow ? 10.0 : 16.0;
        final bottomPad = MediaQuery.paddingOf(context).bottom;
        const columnGap = 8.0;
        const columnCount = 6;
        final columnBottom =
            inset + columnCount * kGeoTouch + (columnCount - 1) * columnGap;
        final showLists = _listsOpen && !(narrow && _selected != null);

        return CallbackShortcuts(
          bindings: {
            if (_layersOpen)
              const SingleActivator(LogicalKeyboardKey.escape): _closeLayers,
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _mapGestureLayer(size, style, channels, recent, saved),
              if (_layersOpen)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _layersOpen = false),
                  ),
                ),
              if (showLists)
                _listsPanel(narrow, inset, size, bottomPad, channels, saved),
              if (_selected != null)
                _infoPanel(_selected!, narrow, inset, size, columnBottom,
                    bottomPad, saved),
              Positioned(
                top: inset,
                left: inset,
                right: narrow ? inset + kGeoTouch + columnGap : null,
                width: narrow ? null : math.min(340.0, size.width - 120),
                child: KeyedSubtree(
                  key: _searchBoxKey,
                  child: GeoSearchField(
                    loadPlaces: _loadPlaces,
                    onPick: (gh) => _focusCell(gh, size),
                    placeLabel: _placeLabel,
                  ),
                ),
              ),
              Positioned(
                top: inset,
                right: inset,
                child: KeyedSubtree(
                  key: _controlsKey,
                  child: _controlColumn(size, columnGap),
                ),
              ),
              if (_layersOpen)
                Positioned(
                  top: inset + 3 * (kGeoTouch + columnGap),
                  right: inset + kGeoTouch + columnGap,
                  width: math.min(
                      240.0, size.width - 2 * inset - kGeoTouch - columnGap),
                  child: GeoLayersMenu(
                    heat: _heatmap,
                    daynight: _daynight,
                    grid: _grid,
                    windowHours: _activeWindowHours,
                    showLocationLegend: _userLocation() != null,
                    showClusterLegend:
                        !_heatmap && _view.zoom < kGeoClusterMaxZoom,
                    showPulseLegend: !_heatmap && !_reduceMotion,
                    reduceMotion: _reduceMotion,
                    onHeat: () {
                      setState(() => _heatmap = !_heatmap);
                      _savePrefs();
                    },
                    onDaynight: () {
                      setState(() => _daynight = !_daynight);
                      _savePrefs();
                    },
                    onGrid: () {
                      setState(() => _grid = !_grid);
                      _savePrefs();
                    },
                    onWindow: _setActiveWindow,
                    onClose: _closeLayers,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _closeLayers() {
    if (!_layersOpen) return;
    setState(() => _layersOpen = false);
    _layersButtonFocus.requestFocus();
  }

  void _openLayersFromKey() {
    if (_layersOpen) return;
    setState(() => _layersOpen = true);
  }

  int get _layerCount => [_heatmap, _daynight, _grid].where((on) => on).length;

  void _syncAmbient(bool want) {
    final run = want && !_reduceMotion;
    if (run && !_ambient.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_ambient.isAnimating && !_reduceMotion) {
          _ambient.repeat();
        }
      });
    } else if (!run && _ambient.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ambient.stop();
        _ambient.value = 0;
      });
    }
  }

  Widget _controlColumn(Size size, double gap) {
    final children = <Widget>[
      GeoControlButton(
        key: const ValueKey('geo-ctl-zoom-in'),
        icon: Icons.add,
        tooltip: tr('Zoom in'),
        onTap: () => _setView(
            _view.zoomedAt(1.6, size.center(Offset.zero), size), size),
      ),
      GeoControlButton(
        key: const ValueKey('geo-ctl-zoom-out'),
        icon: Icons.remove,
        tooltip: tr('Zoom out'),
        onTap: () => _setView(
            _view.zoomedAt(1 / 1.6, size.center(Offset.zero), size), size),
      ),
      GeoControlButton(
        key: const ValueKey('geo-ctl-location'),
        icon: Icons.my_location,
        tooltip: tr('Your Location'),
        active: _userLocation() != null,
        onTap: () => _goToLocation(size),
      ),
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              _openLayersFromKey,
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              _openLayersFromKey,
        },
        child: GeoControlButton(
          key: const ValueKey('geo-ctl-layers'),
          icon: Icons.layers_outlined,
          tooltip: _layerCount > 0
              ? tr('Layers, {n} on', {'n': _layerCount})
              : tr('Layers'),
          active: _layersOpen || _layerCount > 0,
          expanded: _layersOpen,
          focusNode: _layersButtonFocus,
          badge: _layerCount > 0 ? '$_layerCount' : null,
          badgeKey: const ValueKey('geo-layers-count'),
          onTap: () {
            if (_layersOpen) {
              _closeLayers();
            } else {
              setState(() => _layersOpen = true);
            }
          },
        ),
      ),
      GeoControlButton(
        key: const ValueKey('geo-ctl-reset'),
        icon: Icons.public,
        tooltip: tr('Reset View'),
        onTap: () => _resetView(size),
      ),
      GeoControlButton(
        key: const ValueKey('geo-ctl-lists'),
        icon: Icons.list,
        tooltip: tr('Rooms list'),
        active: _listsOpen,
        onTap: () => setState(() {
          _listsOpen = !_listsOpen;
          _layersOpen = false;
          if (_listsOpen) {
            _loadPlaces();
            if (size.width < kGlobeNarrowBreakpoint) _selected = null;
          }
        }),
      ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }

  Widget _panelBox(NymColors nym, Widget child, {Key? key}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: nym.isLight ? const Color(0xF7FFFFFF) : const Color(0xE6000000),
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _listsPanel(bool narrow, double inset, Size size, double bottomPad,
      List<GeohashChannelPoint> channels, Set<String> saved) {
    final nym = context.nym;
    final byGh = {for (final c in channels) c.geohash: c};
    final savedRows = [
      for (final gh in saved.toList()..sort())
        byGh[gh] ??
            () {
              final b = geohashBounds(gh)!;
              return GeoActivity(
                geohash: gh,
                lat: (b.latLo + b.latHi) / 2,
                lng: (b.lngLo + b.lngHi) / 2,
                messages: 0,
              );
            }(),
    ];
    final lists = GeoRoomLists(
      tab: _listTab,
      onTab: (t) => setState(() => _listTab = t),
      active: channels,
      saved: savedRows,
      location: _userLocation(),
      windowHours: _activeWindowHours,
      onWindow: _setActiveWindow,
      placeLabel: _placeLabel,
      onOpen: (gh) => _focusCell(gh, size),
    );
    final panel = _panelBox(nym, lists, key: const ValueKey('geo-lists-panel'));
    if (narrow) {
      return Positioned(
        left: inset,
        right: inset + kGeoTouch + 8,
        bottom: inset + bottomPad,
        height: math.max(220.0, size.height * 0.42),
        child: panel,
      );
    }
    return Positioned(
      left: inset,
      top: inset + kGeoTouch + 8,
      bottom: inset + bottomPad,
      width: 300,
      child: panel,
    );
  }

  Widget _mapGestureLayer(
    Size size,
    GeoMapStyle style,
    List<GeohashChannelPoint> channels,
    Set<String> recent,
    Set<String> saved,
  ) {
    // `grabbing` while dragging, `click` over a dot, else `grab`.
    final cursor = _dragging
        ? SystemMouseCursors.grabbing
        : (_hoveredGeohash != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab);
    final clusters = _clusters(size, channels);

    return MouseRegion(
      cursor: cursor,
      onHover: (event) {
        // Only update hover when not dragging; touch taps select via onTapUp.
        if (_dragging) return;
        final ch = _channelAt(event.localPosition, size);
        final gh = ch?.geohash;
        if (gh != _hoveredGeohash) {
          setState(() => _hoveredGeohash = gh);
        }
      },
      onExit: (_) {
        // Clear hover unless a dot is selected.
        final keep = _selected?.geohash;
        if (_hoveredGeohash != null && _hoveredGeohash != keep) {
          setState(() => _hoveredGeohash = keep);
        }
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final factor = math.exp(-event.scrollDelta.dy * 0.0015);
            _setView(
              _view.zoomedAt(factor, event.localPosition, size),
              size,
            );
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, size),
          onScaleStart: (d) {
            if (_fly.isAnimating) _fly.stop();
            _lastScale = 1.0; // GL-H1: reset the cumulative-scale baseline.
            setState(() => _dragging = true);
          },
          onScaleUpdate: (d) {
            // Pan by per-frame focal deltas converted to degrees.
            final s = _view.scale(size);
            var v = _view.copyWith(
              cx: _view.cx - d.focalPointDelta.dx / s,
              cy: _view.cy + d.focalPointDelta.dy / s,
            );
            // Pinch zoom by the per-frame incremental factor, avoiding compounding runaway.
            if (d.scale != 1.0) {
              final factor = d.scale / _lastScale;
              _lastScale = d.scale;
              v = v.zoomedAt(factor, d.localFocalPoint, size);
            }
            _setView(v, size);
          },
          onScaleEnd: (_) {
            _lastScale = 1.0;
            setState(() => _dragging = false);
          },
          // A CustomPainter isn't bounded by its slot, so clip or zoomed content paints over the header.
          child: ClipRect(
            key: _mapBoxKey,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_selectPulse, _ambient]),
                builder: (context, _) => CustomPaint(
                  key: const ValueKey('geo-map-paint'),
                  size: size,
                  painter: GeoMapPainter(
                    view: _view,
                    style: style,
                    features: _features,
                    admin1Features: _admin1Features,
                    cities: _cities,
                    channels: channels,
                    heatmap: _heatmap,
                    daynight: _daynight,
                    grid: _grid,
                    hoveredGeohash: _hoveredGeohash,
                    userLocation: _userLocation(),
                    heatmapImage: _heatImage,
                    repaint: _ticker,
                    selectedGeohash: _selected?.geohash,
                    selectPulse: _selectPulse.isAnimating && !_reduceMotion
                        ? _selectPulse.value
                        : null,
                    clusters: clusters,
                    recentGeohashes: recent,
                    ambient: _ambient.isAnimating && !_reduceMotion
                        ? _ambient.value
                        : null,
                    savedGeohashes: saved,
                    dpr: capGeoDpr(MediaQuery.devicePixelRatioOf(context)),
                    tiers: _tierPaths,
                    tierLabels: _tierLabels,
                    mapSize: size,
                    occupied: _occupied,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoPanel(GeohashChannelPoint ch, bool narrow, double inset,
      Size size, double columnBottom, double bottomPad, Set<String> saved) {
    final nym = context.nym;
    final gh = ch.geohash.toLowerCase();
    final isSaved = saved.contains(gh);

    // Rows: coordinates (4dp), location, distance (with a user location), messages.
    final coords = '${ch.lat.toStringAsFixed(4)}, ${ch.lng.toStringAsFixed(4)}';
    final user = _userLocation();
    final distance = user == null
        ? null
        : tr('{km} km away', {
            'km': haversineKm(user.lat, user.lng, ch.lat, ch.lng)
                .toStringAsFixed(1)
          });

    Widget action(String key, IconData icon, String tip, VoidCallback onTap,
            {Color? color}) =>
        Semantics(
          button: true,
          label: tip,
          excludeSemantics: true,
          child: NymTooltip(
            message: tip,
            child: InkWell(
              key: ValueKey(key),
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: SizedBox(
                width: kGeoTouch,
                height: kGeoTouch,
                child: Icon(icon, size: 20, color: color ?? nym.textDim),
              ),
            ),
          ),
        );

    final header = Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  '#$gh',
                  style: TextStyle(
                    color: nym.primary,
                    fontSize: 15,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            action(
              'geo-info-save',
              isSaved ? Icons.star : Icons.star_border,
              isSaved ? tr('Remove from saved places') : tr('Save place'),
              () => _toggleSaved(gh),
              color: isSaved ? kSavedMarkerColor : null,
            ),
            action('geo-info-share', Icons.share_outlined, tr('Share place'),
                () => ShareChannelModal.open(context, gh)),
            action('geo-info-close', Icons.close, tr('Close'),
                () => setState(() => _selected = null)),
          ],
        );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _infoRow(tr('Coordinates'), coords, nym),
        _infoRow(tr('Location'), _locationInfo, nym),
        if (distance != null) _infoRow(tr('Distance'), distance, nym),
        _infoRow(tr('Messages'), '${ch.messages}', nym, isLast: true),
        const SizedBox(height: 8),
        GeoPrecisionPath(
          geohash: gh,
          onStep: (prefix) => _focusCell(prefix, size),
        ),
        const SizedBox(height: 10),
        GeoPeekView(key: ValueKey('peek-$gh'), geohash: gh),
      ],
    );
    final join = SizedBox(
          height: kGeoTouch,
          child: TextButton(
            key: const ValueKey('geo-info-join'),
            onPressed: () => _join(gh),
            style: TextButton.styleFrom(
              backgroundColor: nym.primaryA(0.1),
              foregroundColor: nym.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: nym.primaryA(0.3)),
              ),
            ),
            child: Text(
              ch.isJoined ? tr('GO TO CHANNEL') : tr('JOIN CHANNEL'),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5),
            ),
          ),
        );

    final card = _panelBox(
      nym,
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 8),
                child: details,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: join,
            ),
          ],
        ),
      ),
      key: const ValueKey('geo-info-panel'),
    );

    if (narrow) {
      final top = math.min(columnBottom + 8, size.height - inset - bottomPad - 200);
      return Positioned(
        left: inset,
        right: inset,
        top: top,
        bottom: inset + bottomPad,
        child: Align(alignment: Alignment.bottomCenter, child: card),
      );
    }
    return Positioned(
      top: inset,
      right: inset + kGeoTouch + 8,
      width: 330,
      bottom: inset + bottomPad,
      child: Align(alignment: Alignment.topCenter, child: card),
    );
  }

  /// One `Label: value` row with a bottom hairline, dropped on the last row.
  Widget _infoRow(String label, String value, NymColors nym,
      {bool isLast = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: nym.glassBorder)),
            ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontSize: 12,
                color: nym.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(fontSize: 12, color: nym.text),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModalCloseButton extends StatefulWidget {
  const _ModalCloseButton({required this.nym, required this.onTap});

  final NymColors nym;
  final VoidCallback onTap;

  @override
  State<_ModalCloseButton> createState() => _ModalCloseButtonState();
}

class _ModalCloseButtonState extends State<_ModalCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final nym = widget.nym;
    return Semantics(
      button: true,
      label: tr('Close'),
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: const ValueKey('geo-modal-close'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: kGeoTouch,
            height: kGeoTouch,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: const Cubic(0.4, 0, 0.2, 1),
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hovered
                      ? const Color(0x1FFF4444)
                      : const Color(0x0DFFFFFF),
                  border: Border.all(
                    color: _hovered ? const Color(0x4DFF4444) : nym.glassBorder,
                  ),
                ),
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: _hovered ? nym.danger : nym.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

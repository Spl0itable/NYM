import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import 'geo_map_painter.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'topojson.dart';

/// Breakpoint below which the explorer collapses to its phone layout (the PWA's
/// `@media (max-width: 768px)` rules: info panel becomes a bottom bar, the window
/// button group collapses into a `<select>`).
const double kGlobeNarrowBreakpoint = 768;

/// Path to the bundled world map TopoJSON (`countries-110m.json`).
const String kWorldTopoAsset = 'assets/data/countries-110m.json';

/// Path to the bundled admin-1 (state/province) GeoJSON (F2/F3).
const String kAdmin1Asset =
    'assets/data/ne_50m_admin_1_states_provinces_lakes.json';

/// Path to the bundled populated-places (cities) GeoJSON (F4).
const String kCitiesAsset =
    'assets/data/ne_50m_populated_places_simple.json';

/// Zoom at/above which the admin-1 + city detail layers are lazy-loaded
/// (geohash-globe.js:10-11: ADMIN1_ZOOM_THRESHOLD / CITY_ZOOM_THRESHOLD).
const double kSubregionZoomThreshold = 2.5;

/// Active-window options in hours (matches the PWA's `windowOptions`).
const List<int> kActiveWindowOptions = [1, 3, 6, 12, 24];

/// Activity-refresh cadence (`ACTIVE_WINDOW_REFRESH_MS=30000`): re-tally channel
/// counts so the dots/heatmap stay current.
const Duration kActiveWindowRefresh = Duration(milliseconds: 30000);

/// Day/night terminator refresh cadence (`DAYNIGHT_REFRESH_MS=60000`): the
/// terminator drifts slowly, so it repaints half as often as activity (F9).
const Duration kDaynightRefresh = Duration(milliseconds: 60000);

/// Top-level worker entry for [compute]: decode the world TopoJSON off the UI
/// thread. Defined at top level so it can run in an isolate.
List<GeoFeature> decodeWorldFeaturesIsolate(String jsonString) =>
    decodeWorldTopoJson(jsonString);

/// Top-level worker entry for [compute]: decode the admin-1 GeoJSON off the UI
/// thread (the dataset is ~1.7 MB).
List<GeoFeature> decodeAdmin1FeaturesIsolate(String jsonString) =>
    decodeAdmin1GeoJson(jsonString);

/// Top-level worker entry for [compute]: decode the cities GeoJSON off the UI
/// thread.
List<CityPoint> decodeCitiesIsolate(String jsonString) =>
    decodeCitiesGeoJson(jsonString);

/// Session-scoped globe view preferences (GL-L1/GL-L2). The PWA keeps the last
/// Heat / Day-Night / Geohash-grid toggle states and the active-window selection
/// on the in-memory app instance (`_heatmapPreference` / `_daynightPreference` /
/// `_geohashGridPreference`, geohash-globe.js:349-351; `_geohashActiveWindowHours`,
/// :238-243), so reopening the explorer within a session restores them. Flutter
/// pushes a brand-new [GeohashExplorer] each time (sidebar.dart:602), so without a
/// session holder every open would reset all four. This provider is the holder:
/// read in `initState` to seed the widget fields and written from the toggle /
/// window callbacks. No disk persistence — the PWA's preferences aren't persisted
/// either (a fresh app launch starts from these defaults: all toggles off, 24h).
final globePrefsProvider =
    StateProvider<({bool heat, bool daynight, bool grid, int windowHours})>(
  (ref) => (heat: false, daynight: false, grid: false, windowHours: 24),
);

/// The `#geohashExplorerModal` screen — a self-contained equirectangular world
/// map for browsing geohash channels. Pan via drag, zoom via scroll/pinch, an
/// active-window selector, controls (zoom, reset, heat, day/night, grid), a
/// legend, and a channel/cell info panel with a Join button.
///
/// Selecting (Join) a geohash pops this route with the lowercase geohash string
/// so the caller can open that channel: `Navigator.push<String>(...)`.
class GeohashExplorer extends ConsumerStatefulWidget {
  const GeohashExplorer({super.key});

  /// A non-opaque modal route (F11): the app stays visible behind a
  /// `rgba(0,0,0,0.4)` scrim while the explorer card floats over it, matching
  /// the PWA's centered `.geohash-explorer-modal` overlay (instead of a full
  /// opaque page transition). Resolves to the chosen lowercase geohash (or null
  /// if dismissed), so callers keep using `Navigator.push<String>(...)`.
  static Route<String> route() {
    return PageRouteBuilder<String>(
      opaque: false,
      // The scrim is painted by the Scaffold below (which has a `context` and
      // so can resolve light/dark): dark `rgba(0,0,0,0.4)` →
      // `body.light-mode .geohash-explorer-modal { rgba(0,0,0,0.3) }`
      // (styles-themes-responsive.css:681-683). A static `route()` can't read
      // `context.nym`, so the barrier stays transparent here.
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => const GeohashExplorer(),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  ConsumerState<GeohashExplorer> createState() => _GeohashExplorerState();
}

class _GeohashExplorerState extends ConsumerState<GeohashExplorer> {
  GeoView _view = const GeoView();
  List<GeoFeature> _features = const [];
  Size _lastSize = Size.zero;

  // --- Lazy detail layers (F2/F3/F4) ---------------------------------------
  // Admin-1 borders/labels + city dots/labels are loaded on demand once the
  // view zooms to `kSubregionZoomThreshold`, mirroring the PWA's
  // `ensureSubregions`. The `*Loaded` guards prevent a double-load (the PWA
  // flips `admin1Loaded`/`citiesLoaded` true before the promise resolves).
  List<GeoFeature> _admin1Features = const [];
  List<CityPoint> _cities = const [];
  bool _admin1Loaded = false;
  bool _citiesLoaded = false;

  bool _heatmap = false;
  bool _daynight = false;
  bool _grid = false;
  int _activeWindowHours = 24;

  String? _hoveredGeohash;
  bool _dragging = false;

  /// The currently selected channel/cell (drives the info panel + Join).
  GeohashChannelPoint? _selected;

  /// Reverse-geocoded "city, country" for [_selected]; seeded with the PWA's
  /// literal `Loading location...` until the geocode resolves.
  String _locationInfo = tr('Loading location...');

  /// Monotonic token so a stale geocode response can't overwrite a newer
  /// selection's Location row (mirrors re-selecting in the PWA).
  int _geocodeToken = 0;

  // GL-H1 — pinch-zoom baseline. `ScaleUpdateDetails.scale` is cumulative since
  // the gesture started; the PWA anchors zoom to the gesture-start spread
  // (`pinch.zoom * newDist/pinch.dist`, geohash-globe.js:973-990). To reproduce
  // that without exponential runaway we convert the cumulative scale into a
  // per-frame incremental factor (`scale / _lastScale`) applied to the current
  // view. `_lastScale` tracks the previous frame's cumulative scale and is reset
  // to 1.0 on each `onScaleStart`.
  double _lastScale = 1.0;

  // --- Heatmap precompute (F1) ---------------------------------------------
  // The PWA's `drawHeatmap` accumulates blobs into a half-res buffer then
  // remaps per-pixel alpha through the palette; that can't run inside paint, so
  // we build a `ui.Image` off the paint pass and hand it to the painter.
  ui.Image? _heatImage;
  HeatmapInput? _heatInputForImage; // the input that produced _heatImage
  HeatmapInput? _heatInFlight; // the input currently being built
  Timer? _heatDebounce;

  final ApiClient _api = ApiClient();

  // Periodic refresh, split into two cadences to match the PWA exactly (F9):
  //   - activity: re-tally channel counts every ACTIVE_WINDOW_REFRESH_MS (30s);
  //   - day/night: repaint the terminator every DAYNIGHT_REFRESH_MS (60s),
  //     and only while day/night mode is on (the PWA's daynightTimer early-outs
  //     when `!daynightMode`).
  Timer? _activeWindowTimer;
  Timer? _daynightTimer;
  final ValueNotifier<int> _ticker = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    // GL-L1/GL-L2 — restore the last session's toggle/window preferences so a
    // re-open of the explorer keeps Heat/Day-Night/Grid + the active window the
    // user last chose (mirrors the PWA's instance-held preferences).
    final prefs = ref.read(globePrefsProvider);
    _heatmap = prefs.heat;
    _daynight = prefs.daynight;
    _grid = prefs.grid;
    _activeWindowHours = prefs.windowHours;
    _loadFeatures();
    // GL3 — quietly pull recent-activity counts from D1 on open so the globe
    // reflects real activity (especially the default 24h view) for channels we
    // never loaded, mirroring the PWA's `showGeohashExplorer`, which calls
    // `fetchGeohashActivityFromD1` (geohash-globe.js:210). Throttled + best-effort
    // inside the controller; the rebuild on completion re-tallies the dots.
    _refreshD1Activity();
    // Activity tick (30s): refresh D1 activity (throttled), bump the repaint
    // notifier, and rebuild so the dots / heatmap re-tally against the moving
    // active window. Mirrors the PWA's ACTIVE_WINDOW_REFRESH_MS timer, which
    // calls `fetchGeohashActivityFromD1` + `updateGeohashChannels`
    // (geohash-globe.js:1020-1029).
    _activeWindowTimer = Timer.periodic(kActiveWindowRefresh, (_) {
      if (!mounted) return;
      _refreshD1Activity();
      _ticker.value++;
      setState(() {}); // re-run _channels() against the new "now".
    });
    // Day/night tick (60s): repaint only when the terminator is shown.
    _daynightTimer = Timer.periodic(kDaynightRefresh, (_) {
      if (mounted && _daynight) _ticker.value++;
    });
  }

  /// GL3 — fire the controller's throttled D1 activity refresh (the PWA's
  /// `fetchGeohashActivityFromD1`). Folds discovered activity into
  /// `channelLastActivity`, which [buildGeohashChannels] reads as the D1 presence
  /// signal; the resulting `appStateProvider` change rebuilds this widget so the
  /// dots/heatmap re-tally. Best-effort and self-throttling (~30s) in the
  /// controller, so calling it on open and on every 30s tick is safe.
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
    super.dispose();
  }

  Future<void> _loadFeatures() async {
    try {
      final jsonStr = await rootBundle.loadString(kWorldTopoAsset);
      // Decode off the UI thread.
      final feats = await compute(decodeWorldFeaturesIsolate, jsonStr);
      if (!mounted) return;
      setState(() => _features = feats);
    } catch (_) {
      // Leave the map empty (ocean + graticule) if decoding fails.
    }
  }

  /// Lazy-loads the admin-1 + city detail datasets once the view crosses
  /// `kSubregionZoomThreshold`, exactly like the PWA's `ensureSubregions`
  /// (geohash-globe.js:354): each is loaded at most once (the `*Loaded` guard is
  /// flipped before the async decode starts, so a burst of zoom events can't
  /// trigger a second load), decoded off the UI thread, cached, and painted on
  /// arrival. Call after any zoom change.
  void _ensureSubregions() {
    if (_view.zoom >= kSubregionZoomThreshold && !_admin1Loaded) {
      _admin1Loaded = true;
      _loadAdmin1();
    }
    if (_view.zoom >= kSubregionZoomThreshold && !_citiesLoaded) {
      _citiesLoaded = true;
      _loadCities();
    }
  }

  Future<void> _loadAdmin1() async {
    try {
      final jsonStr = await rootBundle.loadString(kAdmin1Asset);
      final feats = await compute(decodeAdmin1FeaturesIsolate, jsonStr);
      if (!mounted) return;
      setState(() => _admin1Features = feats);
    } catch (_) {
      // Leave admin-1 borders absent if decoding fails (allow a retry).
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
      // Leave city dots absent if decoding fails (allow a retry).
      _citiesLoaded = false;
    }
  }

  List<GeohashChannelPoint> _channels() {
    final state = ref.read(appStateProvider);
    return buildGeohashChannels(state, windowHours: _activeWindowHours);
  }

  /// GL4 — change the active window and re-tally. The rebuild re-runs
  /// [_channels] against [hours], and bumping [_ticker] (the painter's repaint
  /// signal) forces the dots/heatmap to redraw immediately — mirroring the PWA's
  /// `setGeohashActiveWindow`, which sets `_geohashActiveWindowHours` then calls
  /// `geohashMap.updatePoints()` (channels.js:329-343). The heat image is keyed
  /// on the windowed point set, so it rebuilds when the count changes too. No D1
  /// refetch (the PWA's window change doesn't refetch either; the 30s tick does).
  void _setActiveWindow(int hours) {
    if (hours == _activeWindowHours) return;
    setState(() => _activeWindowHours = hours);
    _savePrefs();
    _ticker.value++;
  }

  /// GL-L1/GL-L2 — snapshot the current toggle/window preferences into the
  /// session [globePrefsProvider] so a later re-open of the explorer restores
  /// them (the PWA writes these on every toggle/window change, geohash-globe.js
  /// :1090/1096/1102 and channels.js:329-343).
  void _savePrefs() {
    ref.read(globePrefsProvider.notifier).state = (
      heat: _heatmap,
      daynight: _daynight,
      grid: _grid,
      windowHours: _activeWindowHours,
    );
  }

  /// The user's location for the map marker / distance row, but only when the
  /// PWA would show it: `settings.sortByProximity && userLocation` (matches
  /// `showYourLocation` in geohash-globe.js:236).
  ({double lat, double lng})? _userLocation() {
    final sortByProximity =
        ref.read(settingsProvider).sortByProximity;
    final loc = ref.read(userLocationProvider);
    if (!sortByProximity || loc == null) return null;
    return (lat: loc.lat, lng: loc.lng);
  }

  void _setView(GeoView v, Size size) {
    setState(() => _view = v.clamped(size));
    // Trigger the admin-1/city lazy-load on any zoom change (PWA calls
    // `ensureSubregions` from onWheel/onTouchMove/zoomBy/zoomToBounds).
    _ensureSubregions();
  }

  // --- Heatmap image lifecycle (F1) ----------------------------------------

  /// (Re)builds the heatmap [ui.Image] when [heatmap] is on and the inputs
  /// (view/size/activity) changed, debounced like the PWA's throttled redraw.
  /// No-op (and clears any cached image) when heatmap mode is off.
  void _maybeRebuildHeat(Size size, List<GeohashChannelPoint> channels) {
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
      points: [
        for (final c in channels)
          (lng: c.lng, lat: c.lat, messages: c.messages),
      ],
    );
    // Already current or already building this exact input — nothing to do.
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
        // Drop the result if the inputs moved on while we were building.
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

  // --- Gesture handling -----------------------------------------------------

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
    final local = d.localPosition;
    final ch = _channelAt(local, size);
    if (ch != null) {
      // PWA (`geohash-globe.js` onPointerUp): tapping a channel dot calls
      // `selectGeohashChannel(ch)` only — it selects/joins without re-framing
      // the camera. Only a grid-cell tap (`_selectGeohashCell`) zooms to bounds.
      _selectChannel(ch);
      return;
    }
    if (_grid) {
      final u = _view.unproject(local.dx, local.dy, size);
      if (u.lat < -90 || u.lat > 90 || u.lng < -180 || u.lng > 180) return;
      final precision = computeGridPrecision(_view, size);
      final gh = encodeGeohash(u.lat, u.lng, precision: precision);
      _selectCell(gh, size);
    }
  }

  /// Selects a channel/cell for the info panel and (re)starts a reverse-geocode
  /// for its Location row. Mirrors `selectGeohashChannel` (channels.js:345): the
  /// Location row shows `Loading location...` until the geocode resolves.
  void _selectChannel(GeohashChannelPoint point) {
    final token = ++_geocodeToken;
    setState(() {
      _selected = point;
      _hoveredGeohash = point.geohash;
      _locationInfo = tr('Loading location...');
    });
    _fetchLocation(point.lat, point.lng, token);
  }

  /// Reverse-geocodes (lat,lng) → "city, country" (`fetchGeocode(lat,lng,10)`),
  /// updating the Location row only if [token] is still the active selection.
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

  /// Mirrors `_selectGeohashCell`: zoom to the cell, reuse an existing channel
  /// entry if present, else synthesize one.
  void _selectCell(String geohash, Size size) {
    final gh = geohash.toLowerCase();
    final bounds = geohashBounds(gh);
    if (bounds == null) return;
    final existing = _channels().where((c) => c.geohash == gh);
    final point = existing.isNotEmpty
        ? existing.first
        : GeohashChannelPoint(
            geohash: gh,
            lat: (bounds.latLo + bounds.latHi) / 2,
            lng: (bounds.lngLo + bounds.lngHi) / 2,
            messages: 0,
            isJoined: false,
          );
    _selectChannel(point);
    // `zoomToBounds` in the PWA also calls `ensureSubregions` after re-framing.
    _setView(_view.fitBounds(bounds, size), size);
  }

  void _resetView(Size size) {
    setState(() {
      _view = const GeoView().clamped(size);
      _heatmap = false;
      _daynight = false;
      _grid = false;
      _selected = null;
      _hoveredGeohash = null;
      _locationInfo = tr('Loading location...');
      _activeWindowHours = 24;
    });
    // GL-L1/GL-L2 — Reset View clears the session preferences too (the PWA's
    // reset nulls `_heatmapPreference`/etc. and forces the window back to 24,
    // geohash-globe.js:1062/1067/1072/1218-1220), so a later re-open starts from
    // the home state rather than restoring the pre-reset toggles.
    _savePrefs();
  }

  void _join(String geohash) {
    Navigator.of(context).pop(geohash.toLowerCase());
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final style = GeoMapStyle.resolve(
      isLight: nym.isLight,
      primary: nym.primary,
      warning: nym.warning,
    );

    // F11 — the PWA explorer is a centered overlay that floats over the
    // still-visible app, with a 90%×90% (max 1200×800) card carrying
    // `shadow-lg` + `shadow-glow`. The scaffold paints the translucent scrim
    // (it has a context, so it resolves light/dark): dark `rgba(0,0,0,0.4)` →
    // `body.light-mode .geohash-explorer-modal { rgba(0,0,0,0.3) }`
    // (styles-themes-responsive.css:681-683). Under a non-opaque [route] the
    // barrier is transparent and this scrim is the only dimming layer (still
    // translucent, so the app shows through); under a plain opaque route it also
    // covers the black void behind the card.
    return Scaffold(
      backgroundColor: nym.isLight
          ? const Color(0x4D000000) // black @ 0.3
          : const Color(0x66000000), // black @ 0.4
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
                  // `.geohash-explorer-content border-radius: var(--radius-xl)` = 24px.
                  borderRadius: BorderRadius.circular(24),
                  // `body.light-mode .geohash-explorer-content { box-shadow:
                  // 0 8px 40px rgba(0,0,0,0.12) }` — one soft shadow, no glow in
                  // light (styles-themes-responsive.css:1054-1056).
                  boxShadow: nym.isLight
                      ? const [
                          BoxShadow(
                            color: Color(0x1F000000), // black @ 0.12
                            blurRadius: 40,
                            offset: Offset(0, 8),
                          ),
                        ]
                      : [
                          // --shadow-lg: 0 8px 32px rgba(0,0,0,0.5)
                          const BoxShadow(
                            color: Color(0x80000000),
                            blurRadius: 32,
                            offset: Offset(0, 8),
                          ),
                          // --shadow-glow: 0 0 20px rgb(from primary / 0.1)
                          BoxShadow(color: nym.primaryA(0.1), blurRadius: 20),
                        ],
                ),
                clipBehavior: Clip.antiAlias,
                // `.modal-close` is `position:absolute` within
                // `.geohash-explorer-content`, so float it over the card via a
                // Stack rather than inlining it in the header row.
                child: Stack(
                  children: [
                    Column(
                      children: [
                        _header(nym),
                        Expanded(child: _body(style)),
                      ],
                    ),
                    // top:14 right:14, 32×32 circular chip.
                    Positioned(
                      top: 14,
                      right: 14,
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
      // `.geohash-explorer-header { padding: 16px 24px; padding-right: 56px; }`
      // — the right gutter reserves room for the absolute `.modal-close` chip.
      // A block element: full width, LEFT-aligned title (never centered).
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 56, 16),
      decoration: BoxDecoration(
        color: const Color(0x26000000), // rgba(0,0,0,0.15)
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
        // On first layout (or resize) clamp the view to the new size.
        if (size != _lastSize) {
          _lastSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _view = _view.clamped(size));
          });
        }

        // Watch the store so heatmap/dots reflect activity changes, and the
        // proximity flag/location so the "Your Location" legend row + marker
        // appear/disappear live.
        ref.watch(appStateProvider);
        ref.watch(settingsProvider.select((s) => s.sortByProximity));
        ref.watch(userLocationProvider);
        final channels = _channels();

        // Keep the precomputed heatmap image in sync with the current inputs.
        _maybeRebuildHeat(size, channels);

        final narrow = size.width < kGlobeNarrowBreakpoint;

        return Stack(
          fit: StackFit.expand,
          children: [
            _mapGestureLayer(size, style, channels),
            _topLeftControls(size, narrow),
            _bottomControls(narrow),
            _legend(narrow),
            if (_selected != null) _infoPanel(_selected!, narrow),
          ],
        );
      },
    );
  }

  Widget _mapGestureLayer(
    Size size,
    GeoMapStyle style,
    List<GeohashChannelPoint> channels,
  ) {
    // Desktop cursor (F6): `grabbing` while dragging, `click` over a dot, else
    // `grab` — mirrors `onPointerMove`/`onPointerDown` in geohash-globe.js.
    final cursor = _dragging
        ? SystemMouseCursors.grabbing
        : (_hoveredGeohash != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab);

    return MouseRegion(
      cursor: cursor,
      onHover: (event) {
        // Only update the hovered dot when not dragging (PWA gates on
        // `!dragging`). Touch taps drive selection separately via onTapUp.
        if (_dragging) return;
        final ch = _channelAt(event.localPosition, size);
        final gh = ch?.geohash;
        if (gh != _hoveredGeohash) {
          setState(() => _hoveredGeohash = gh);
        }
      },
      onExit: (_) {
        // Clear hover unless a dot is selected (keep the selected dot enlarged).
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
            _lastScale = 1.0; // GL-H1: reset the cumulative-scale baseline.
            setState(() => _dragging = true);
          },
          onScaleUpdate: (d) {
            // Pan: translate the incremental focal-point delta into degrees,
            // applied to the *current* view (PWA pans by per-frame deltas).
            final s = _view.scale(size);
            var v = _view.copyWith(
              cx: _view.cx - d.focalPointDelta.dx / s,
              cy: _view.cy + d.focalPointDelta.dy / s,
            );
            // GL-H1 — pinch zoom around the focal point using the per-frame
            // INCREMENTAL factor (cumulative `d.scale` / last cumulative), not
            // the cumulative scale itself. This matches the PWA's linear
            // finger-spread→zoom mapping (geohash-globe.js:973-990) instead of
            // compounding `zoomₙ = zoomₙ₋₁ × d.scaleₙ` and running away.
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
          child: RepaintBoundary(
            child: CustomPaint(
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
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topLeftControls(Size size, bool narrow) {
    // PWA: `.geohash-controls-tl` top/left 20px, → 10px under 768px.
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      top: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn('+',
              onTap: () =>
                  _setView(_view.zoomedAt(1.6, size.center(Offset.zero), size),
                      size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn('−',
              onTap: () => _setView(
                  _view.zoomedAt(1 / 1.6, size.center(Offset.zero), size), size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn(tr('Reset View'), onTap: () => _resetView(size)),
        ],
      ),
    );
  }

  Widget _bottomControls(bool narrow) {
    // PWA: `.geohash-controls` bottom/left 20px, → 10px under 768px.
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn(tr('Heat'),
              active: _heatmap,
              onTap: () {
                setState(() => _heatmap = !_heatmap);
                _savePrefs();
              }),
          const SizedBox(width: 10),
          _controlBtn(tr('Day / Night'),
              active: _daynight,
              onTap: () {
                setState(() => _daynight = !_daynight);
                _savePrefs();
              }),
          const SizedBox(width: 10),
          _controlBtn(tr('Geohash'),
              active: _grid,
              onTap: () {
                setState(() => _grid = !_grid);
                _savePrefs();
              }),
        ],
      ),
    );
  }

  Widget _legend(bool narrow) {
    final nym = context.nym;
    // Show the "Your Location" row only when the PWA would (`showYourLocation`:
    // proximity sort on AND a known location), matching geohash-globe.js:236.
    final showYourLocation = _userLocation() != null;
    // On narrow layouts the font shrinks 10→9 and the inset moves 20→10.
    final fontSize = narrow ? 9.0 : 10.0;
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      right: inset,
      child: Container(
        // `.geohash-legend` padding 0 14px; the items carry the vertical margin.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xB3000000), // rgba(0,0,0,0.7)
          border: Border.all(color: nym.glassBorder),
          // `.geohash-legend border-radius: var(--radius-sm)` = 12px.
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Active row: dot (with primary glow) + "Active" + window control.
            _legendRow(
              dotColor: nym.primary,
              // `.nm-geo-1 { box-shadow: 0 0 5px var(--primary); }`
              glow: nym.primary,
              label: tr('Active'),
              fontSize: fontSize,
              trailing: narrow ? _windowSelect(nym) : _windowGroup(nym),
            ),
            if (showYourLocation) ...[
              const SizedBox(height: 5),
              _legendRow(
                dotColor: nym.warning, // `.nm-geo-2 { background: var(--warning); }`
                label: tr('Your Location'),
                fontSize: fontSize,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _legendRow({
    required Color dotColor,
    required String label,
    required double fontSize,
    Color? glow,
    Widget? trailing,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: glow == null
                ? null
                : [BoxShadow(color: glow, blurRadius: 5)],
          ),
        ),
        const SizedBox(width: 8),
        // `.geohash-legend` sets no `color`, so the `<span>` inherits `--text`
        // (the themed accent), not a fixed gray.
        Text(label,
            style: TextStyle(fontSize: fontSize, color: context.nym.text)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing,
        ],
      ],
    );
  }

  Widget _windowGroup(NymColors nym) {
    // `.geohash-window-btn { border-left: 1px solid var(--glass-border); }` with
    // `:first-child { border-left: 0; }` → a 1px hairline divider BETWEEN each
    // button (1h|3h|6h|12h|24h), not before the first.
    final children = <Widget>[];
    for (var i = 0; i < kActiveWindowOptions.length; i++) {
      if (i > 0) {
        // A full-height 1px divider (border-left spans the button's content box).
        children.add(Container(width: 1, color: nym.glassBorder));
      }
      final h = kActiveWindowOptions[i];
      children.add(_windowBtn(h, h == _activeWindowHours, nym));
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: nym.glassBorder),
        // `.geohash-window-group border-radius: var(--radius-xs)` = 8px.
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      // IntrinsicHeight lets the 1px dividers stretch to the button height,
      // matching the CSS `border-left` that covers the full content box.
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  /// The compact `<select>` fallback shown under 768px in place of the button
  /// group (`.geohash-window-select`: rgba(255,255,255,0.05) bg, glassBorder,
  /// fontSize 11, padding 2/6).
  Widget _windowSelect(NymColors nym) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF), // rgba(255,255,255,0.05)
        border: Border.all(color: nym.glassBorder),
        // `.geohash-window-select border-radius: var(--radius-xs)` = 8px.
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _activeWindowHours,
          isDense: true,
          dropdownColor: const Color(0xF2000000),
          iconSize: 14,
          icon: Icon(Icons.arrow_drop_down, color: nym.text),
          style: TextStyle(fontSize: 11, color: nym.text),
          items: [
            for (final h in kActiveWindowOptions)
              DropdownMenuItem<int>(value: h, child: Text('${h}h')),
          ],
          onChanged: (h) {
            if (h != null) _setActiveWindow(h); // GL4
          },
        ),
      ),
    );
  }

  Widget _windowBtn(int hours, bool active, NymColors nym) {
    return InkWell(
      onTap: () => _setActiveWindow(hours), // GL4
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        color: active ? nym.primaryA(0.18) : Colors.transparent,
        child: Text(
          '${hours}h',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: active ? nym.primary : nym.textDim,
          ),
        ),
      ),
    );
  }

  Widget _infoPanel(GeohashChannelPoint ch, bool narrow) {
    final nym = context.nym;

    // PWA rows (channels.js:361-372): Coordinates (decimal, 4dp), Location
    // (reverse-geocoded, "Loading location..." until resolved), Distance (only
    // when a user location is known), Messages. No Status row.
    final coords =
        '${ch.lat.toStringAsFixed(4)}, ${ch.lng.toStringAsFixed(4)}';
    final user = _userLocation();
    final distance = user == null
        ? null
        : tr('{km} km away', {
            'km': _distanceKm(user.lat, user.lng, ch.lat, ch.lng)
                .toStringAsFixed(1)
          });

    final rows = <Widget>[
      _infoRow(tr('Coordinates'), coords, nym),
      _infoRow(tr('Location'), _locationInfo, nym),
      if (distance != null) _infoRow(tr('Distance'), distance, nym),
      _infoRow(tr('Messages'), '${ch.messages}', nym, isLast: true),
    ];

    final card = Container(
      width: narrow ? null : 300, // narrow: stretch via Positioned left/right.
      // `.geohash-info-panel { padding: 16px; padding-right: 36px; }` — the right
      // gutter reserves room for the absolute `.geohash-info-close` chip.
      padding: const EdgeInsets.fromLTRB(16, 16, 36, 16),
      decoration: BoxDecoration(
        color: const Color(0xB3000000), // rgba(0,0,0,0.7)
        border: Border.all(color: nym.glassBorder),
        // `.geohash-info-panel border-radius: var(--radius-md)` = 16px.
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // `.geohash-info-title { text-transform: lowercase; }`
            '#${ch.geohash.toLowerCase()}',
            style: TextStyle(
              color: nym.primary,
              fontSize: 14,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          ...rows,
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => _join(ch.geohash),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.all(9),
                backgroundColor: nym.primaryA(0.1),
                foregroundColor: nym.primary,
                shape: RoundedRectangleBorder(
                  // `.geohash-join-btn border-radius: var(--radius-xs)` = 8px.
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: nym.primaryA(0.3)),
                ),
              ),
              child: Text(
                // PWA: `Go to Channel` when joined, else `Join Channel`
                // (uppercased by `.geohash-join-btn { text-transform: uppercase }`).
                ch.isJoined ? tr('GO TO CHANNEL') : tr('JOIN CHANNEL'),
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5),
              ),
            ),
          ),
        ],
      ),
    );

    // `.geohash-info-close` is `position:absolute; top:8; right:8` within the
    // panel — float the 24×24 chip over the card via a Stack instead of inlining
    // it in the title row.
    final panel = Stack(
      children: [
        card,
        Positioned(
          top: 8,
          right: 8,
          child: _InfoCloseButton(
            nym: nym,
            onTap: () => setState(() => _selected = null),
          ),
        ),
      ],
    );

    // Under 768px the panel becomes a fixed bottom bar (bottom:60 left/right:10,
    // max-width:none); otherwise it sits top-right (top:20 right:20).
    return narrow
        ? Positioned(bottom: 60, left: 10, right: 10, child: panel)
        : Positioned(top: 20, right: 20, child: panel);
  }

  /// Haversine great-circle distance in km (`calculateDistance`,
  /// geohash-globe.js:1271, R = 6371).
  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    const deg = math.pi / 180;
    final dLat = (lat2 - lat1) * deg;
    final dLon = (lon2 - lon1) * deg;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * deg) *
            math.cos(lat2 * deg) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  /// One info row rendered as `Label: value` on a single wrapped line, with the
  /// PWA's 5px vertical margin/padding and a 1px bottom hairline (`.geohash-
  /// info-item`); the last row drops the border.
  Widget _infoRow(String label, String value, NymColors nym,
      {bool isLast = false}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(vertical: 5),
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
                fontWeight: FontWeight.w700, // <strong>
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

  Widget _controlBtn(
    String label, {
    required VoidCallback onTap,
    bool active = false,
    double? width,
  }) {
    final nym = context.nym;
    // `.geohash-control-btn border-radius: var(--radius-xs)` = 8px.
    final radius = BorderRadius.circular(8);
    return SizedBox(
      width: width,
      // `.geohash-control-btn.active { box-shadow: 0 0 12px rgb(from primary / 0.25); }`
      // — the outer glow lives outside the Material's clip so it renders.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: active
              ? [BoxShadow(color: nym.primaryA(0.25), blurRadius: 12)]
              : null,
        ),
        child: Material(
          color: active ? nym.primaryA(0.18) : const Color(0xB3000000),
          borderRadius: radius,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Container(
              padding: width != null
                  ? const EdgeInsets.symmetric(vertical: 8)
                  : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(
                    color: active ? nym.primaryA(0.5) : nym.glassBorder),
                borderRadius: radius,
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: width != null ? 16 : 11,
                  fontWeight: width != null ? FontWeight.w600 : FontWeight.w500,
                  color: active ? nym.primary : nym.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header `✕` chip — a 32×32 circular `.modal-close` button
/// (`styles-components.css:91-115`). Idle: `rgba(255,255,255,0.05)` fill,
/// `glassBorder` ring, `text-dim` glyph at 16px. Hover: `rgba(255,68,68,0.12)`
/// fill, `danger` glyph, `rgba(255,68,68,0.3)` ring.
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // `transition: all var(--transition)` = 0.25s cubic-bezier(0.4,0,0.2,1).
          duration: const Duration(milliseconds: 250),
          curve: const Cubic(0.4, 0, 0.2, 1),
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovered
                ? const Color(0x1FFF4444) // rgba(255,68,68,0.12)
                : const Color(0x0DFFFFFF), // rgba(255,255,255,0.05)
            border: Border.all(
              color: _hovered
                  ? const Color(0x4DFF4444) // rgba(255,68,68,0.3)
                  : nym.glassBorder,
            ),
          ),
          child: Text(
            '✕', // ✕
            style: TextStyle(
              fontSize: 16,
              height: 1,
              color: _hovered ? nym.danger : nym.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// The info-panel `✕` chip — a 24×24 `.geohash-info-close` button
/// (`styles-components.css:1800-1821`). Idle: transparent fill + transparent
/// border, `radius-xs`(8), `text-dim` glyph at 12px. Hover: `rgba(255,255,255,0.08)`
/// fill, `text` glyph, `glassBorder` ring.
class _InfoCloseButton extends StatefulWidget {
  const _InfoCloseButton({required this.nym, required this.onTap});

  final NymColors nym;
  final VoidCallback onTap;

  @override
  State<_InfoCloseButton> createState() => _InfoCloseButtonState();
}

class _InfoCloseButtonState extends State<_InfoCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final nym = widget.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: const Cubic(0.4, 0, 0.2, 1),
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // `border-radius: var(--radius-xs)` = 8px.
            borderRadius: BorderRadius.circular(8),
            color: _hovered
                ? const Color(0x14FFFFFF) // rgba(255,255,255,0.08)
                : Colors.transparent,
            border: Border.all(
              color: _hovered ? nym.glassBorder : Colors.transparent,
            ),
          ),
          child: Text(
            '✕', // ✕
            style: TextStyle(
              fontSize: 12,
              height: 1,
              color: _hovered ? nym.text : nym.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

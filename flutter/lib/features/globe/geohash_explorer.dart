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

/// Below this width the explorer uses its phone layout.
const double kGlobeNarrowBreakpoint = 768;


const String kAdmin1Asset =
    'assets/data/ne_50m_admin_1_states_provinces_lakes.json';

const String kCitiesAsset = 'assets/data/ne_50m_populated_places_simple.json';

/// Zoom at which admin-1 and city layers lazy-load.
const double kSubregionZoomThreshold = 2.5;

/// Active-window options in hours.
const List<int> kActiveWindowOptions = [1, 3, 6, 12, 24];

/// Re-tally channel activity every 30s.
const Duration kActiveWindowRefresh = Duration(milliseconds: 30000);

/// Repaint the day/night terminator every 60s.
const Duration kDaynightRefresh = Duration(milliseconds: 60000);

/// Isolate entry for [compute] decoding the world TopoJSON.
List<GeoFeature> decodeWorldFeaturesIsolate(String jsonString) =>
    decodeWorldTopoJson(jsonString);

/// Isolate entry for [compute] decoding the ~1.7 MB admin-1 GeoJSON.
List<GeoFeature> decodeAdmin1FeaturesIsolate(String jsonString) =>
    decodeAdmin1GeoJson(jsonString);

/// Isolate entry for [compute] decoding the cities GeoJSON.
List<CityPoint> decodeCitiesIsolate(String jsonString) =>
    decodeCitiesGeoJson(jsonString);

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
      // The Scaffold paints the mode-aware scrim, since this static route has no context.
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => GeohashExplorer(focusGeohash: focusGeohash),
      transitionsBuilder: (_, animation, _, child) =>
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

  /// Whether [GeohashExplorer.focusGeohash] has been framed yet.
  bool _focusApplied = false;

  // Admin-1 and city layers load once past the zoom threshold; the loaded flags flip first to prevent double loads.
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

  @override
  void initState() {
    super.initState();
    // Restore this session's toggles and active window.
    final prefs = ref.read(globePrefsProvider);
    _heatmap = prefs.heat;
    _daynight = prefs.daynight;
    _grid = prefs.grid;
    _activeWindowHours = prefs.windowHours;
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
      // Decoding failed: leave an empty map.
    }
  }

  /// Loads admin-1 and city data once each past the zoom threshold, decoded off the UI thread; call after any zoom change.
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

  List<GeohashChannelPoint> _channels() {
    final state = ref.read(appStateProvider);
    return buildGeohashChannels(state, windowHours: _activeWindowHours);
  }

  /// Changes the window and forces an immediate redraw; no D1 refetch.
  void _setActiveWindow(int hours) {
    if (hours == _activeWindowHours) return;
    setState(() => _activeWindowHours = hours);
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
    setState(() => _view = v.clamped(size));
    // Trigger the lazy detail load on any zoom change.
    _ensureSubregions();
  }

  /// Rebuilds the heatmap image when inputs change; clears it when heatmap is off.
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
      // Tapping a dot selects without re-framing; only grid-cell taps zoom.
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

  /// Selects for the info panel and starts a reverse geocode for its Location row.
  void _selectChannel(GeohashChannelPoint point) {
    final token = ++_geocodeToken;
    setState(() {
      _selected = point;
      _hoveredGeohash = point.geohash;
      _locationInfo = tr('Loading location...');
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

  /// Zooms to the cell, reusing an existing channel entry or synthesizing one.
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
    // Re-framing also triggers the lazy detail load.
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
    // Reset also clears the session preferences.
    _savePrefs();
  }

  void _join(String geohash) {
    Navigator.of(context).pop(geohash.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final style = GeoMapStyle.resolve(
      isLight: nym.isLight,
      primary: nym.primary,
      warning: nym.warning,
    );

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
              _selectCell(focus, size);
            }
          });
        }

        // Watch the store and location so dots, heatmap and the location row update live.
        ref.watch(appStateProvider);
        ref.watch(settingsProvider.select((s) => s.sortByProximity));
        ref.watch(userLocationProvider);
        final channels = _channels();

        // Keep the heatmap image in sync with the current inputs.
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
    // `grabbing` while dragging, `click` over a dot, else `grab`.
    final cursor = _dragging
        ? SystemMouseCursors.grabbing
        : (_hoveredGeohash != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab);

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
      ),
    );
  }

  Widget _topLeftControls(Size size, bool narrow) {
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      top: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn('+',
              onTap: () => _setView(
                  _view.zoomedAt(1.6, size.center(Offset.zero), size), size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn('−',
              onTap: () => _setView(
                  _view.zoomedAt(1 / 1.6, size.center(Offset.zero), size),
                  size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn(tr('Reset View'), onTap: () => _resetView(size)),
        ],
      ),
    );
  }

  Widget _bottomControls(bool narrow) {
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn(tr('Heat'), active: _heatmap, onTap: () {
            setState(() => _heatmap = !_heatmap);
            _savePrefs();
          }),
          const SizedBox(width: 10),
          _controlBtn(tr('Day / Night'), active: _daynight, onTap: () {
            setState(() => _daynight = !_daynight);
            _savePrefs();
          }),
          const SizedBox(width: 10),
          _controlBtn(tr('Geohash'), active: _grid, onTap: () {
            setState(() => _grid = !_grid);
            _savePrefs();
          }),
        ],
      ),
    );
  }

  Widget _legend(bool narrow) {
    final nym = context.nym;
    // Only with proximity sort on and a known location.
    final showYourLocation = _userLocation() != null;
    final fontSize = narrow ? 9.0 : 10.0;
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      right: inset,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          border: Border.all(color: nym.glassBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _legendRow(
              dotColor: nym.primary,
              glow: nym.primary,
              label: tr('Active'),
              fontSize: fontSize,
              trailing: narrow ? _windowSelect(nym) : _windowGroup(nym),
            ),
            if (showYourLocation) ...[
              const SizedBox(height: 5),
              _legendRow(
                dotColor:
                    nym.warning,
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
            boxShadow:
                glow == null ? null : [BoxShadow(color: glow, blurRadius: 5)],
          ),
        ),
        const SizedBox(width: 8),
        // Inherits `--text`, not a fixed gray.
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
    // 1px dividers between window buttons, not before the first.
    final children = <Widget>[];
    for (var i = 0; i < kActiveWindowOptions.length; i++) {
      if (i > 0) {
        children.add(Container(width: 1, color: nym.glassBorder));
      }
      final h = kActiveWindowOptions[i];
      children.add(_windowBtn(h, h == _activeWindowHours, nym));
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      // IntrinsicHeight lets the dividers stretch to button height.
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  /// Compact dropdown shown under 768px instead of the button group.
  Widget _windowSelect(NymColors nym) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        border: Border.all(color: nym.glassBorder),
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
            if (h != null) _setActiveWindow(h);
          },
        ),
      ),
    );
  }

  Widget _windowBtn(int hours, bool active, NymColors nym) {
    return InkWell(
      onTap: () => _setActiveWindow(hours),
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

    // Rows: coordinates (4dp), location, distance (with a user location), messages.
    final coords = '${ch.lat.toStringAsFixed(4)}, ${ch.lng.toStringAsFixed(4)}';
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
      // Right padding reserves room for the close chip.
      padding: const EdgeInsets.fromLTRB(16, 16, 36, 16),
      decoration: BoxDecoration(
        color: const Color(0xB3000000),
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
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
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: nym.primaryA(0.3)),
                ),
              ),
              child: Text(
                // "Go to Channel" when joined, else "Join Channel".
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

    // The close chip floats over the panel via a Stack.
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

    // Under 768px a bottom bar, otherwise top-right.
    return narrow
        ? Positioned(bottom: 60, left: 10, right: 10, child: panel)
        : Positioned(top: 20, right: 20, child: panel);
  }

  /// Haversine distance in km (R = 6371).
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

  /// One `Label: value` row with a bottom hairline, dropped on the last row.
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

  Widget _controlBtn(
    String label, {
    required VoidCallback onTap,
    bool active = false,
    double? width,
  }) {
    final nym = context.nym;
    final radius = BorderRadius.circular(8);
    return SizedBox(
      width: width,
      // The active glow sits outside the Material's clip so it renders.
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

/// 32x32 circular close chip that turns danger-red on hover.
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
          // 0.25s cubic-bezier(0.4, 0, 0.2, 1).
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
              color: _hovered
                  ? const Color(0x4DFF4444)
                  : nym.glassBorder,
            ),
          ),
          child: Text(
            '✕',
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

/// 24x24 info-panel close chip, transparent until hover.
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
            borderRadius: BorderRadius.circular(8),
            color: _hovered
                ? const Color(0x14FFFFFF)
                : Colors.transparent,
            border: Border.all(
              color: _hovered ? nym.glassBorder : Colors.transparent,
            ),
          ),
          child: Text(
            '✕',
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

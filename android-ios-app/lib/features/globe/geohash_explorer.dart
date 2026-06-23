import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import 'geo_map_painter.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'topojson.dart';

/// Path to the bundled world map TopoJSON (`countries-110m.json`).
const String kWorldTopoAsset = 'assets/data/countries-110m.json';

/// Active-window options in hours (matches the PWA's `windowOptions`).
const List<int> kActiveWindowOptions = [1, 3, 6, 12, 24];

/// Top-level worker entry for [compute]: decode the world TopoJSON off the UI
/// thread. Defined at top level so it can run in an isolate.
List<GeoFeature> decodeWorldFeaturesIsolate(String jsonString) =>
    decodeWorldTopoJson(jsonString);

/// The `#geohashExplorerModal` screen — a self-contained equirectangular world
/// map for browsing geohash channels. Pan via drag, zoom via scroll/pinch, an
/// active-window selector, controls (zoom, reset, heat, day/night, grid), a
/// legend, and a channel/cell info panel with a Join button.
///
/// Selecting (Join) a geohash pops this route with the lowercase geohash string
/// so the caller can open that channel: `Navigator.push<String>(...)`.
class GeohashExplorer extends ConsumerStatefulWidget {
  const GeohashExplorer({super.key});

  @override
  ConsumerState<GeohashExplorer> createState() => _GeohashExplorerState();
}

class _GeohashExplorerState extends ConsumerState<GeohashExplorer> {
  GeoView _view = const GeoView();
  List<GeoFeature> _features = const [];
  Size _lastSize = Size.zero;

  bool _heatmap = false;
  bool _daynight = false;
  bool _grid = false;
  int _activeWindowHours = 24;

  String? _hoveredGeohash;

  /// The currently selected channel/cell (drives the info panel + Join).
  GeohashChannelPoint? _selected;

  // Drag state.
  GeoView? _dragStartView;

  // Periodic refresh (heatmap activity / day-night), like the PWA's intervals.
  Timer? _refreshTimer;
  final ValueNotifier<int> _ticker = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _loadFeatures();
    // Refresh activity counts (30s) and day/night (60s); a single 30s tick that
    // rebuilds is sufficient for our read-only store.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _ticker.value++;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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

  List<GeohashChannelPoint> _channels() {
    final state = ref.read(appStateProvider);
    return buildGeohashChannels(state, windowHours: _activeWindowHours);
  }

  void _setView(GeoView v, Size size) {
    setState(() => _view = v.clamped(size));
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
      setState(() {
        _selected = ch;
        _hoveredGeohash = ch.geohash;
      });
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
    setState(() {
      _selected = point;
      _hoveredGeohash = gh;
    });
    _view = _view.fitBounds(bounds, size).clamped(size);
  }

  void _resetView(Size size) {
    setState(() {
      _view = const GeoView().clamped(size);
      _heatmap = false;
      _daynight = false;
      _grid = false;
      _selected = null;
      _hoveredGeohash = null;
      _activeWindowHours = 24;
    });
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

    return Scaffold(
      backgroundColor: const Color(0x66000000), // modal scrim rgba(0,0,0,0.4)
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 800),
            child: FractionallySizedBox(
              widthFactor: 0.95,
              heightFactor: 0.95,
              child: Container(
                decoration: BoxDecoration(
                  color: nym.bgSecondary,
                  border: Border.all(color: nym.glassBorder),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _header(nym),
                    Expanded(child: _body(style)),
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
      padding: const EdgeInsets.fromLTRB(24, 16, 8, 16),
      decoration: BoxDecoration(
        color: const Color(0x26000000), // rgba(0,0,0,0.15)
        border: Border(bottom: BorderSide(color: nym.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'GEOHASH EXPLORER',
              style: TextStyle(
                fontSize: 18,
                color: nym.primary,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: Icon(Icons.close, color: nym.textDim, size: 18),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
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

        // Watch the store so heatmap/dots reflect activity changes.
        ref.watch(appStateProvider);
        final channels = _channels();

        return Stack(
          fit: StackFit.expand,
          children: [
            _mapGestureLayer(size, style, channels),
            _topLeftControls(size),
            _bottomControls(),
            _legend(),
            if (_selected != null) _infoPanel(_selected!),
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
    return Listener(
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
          _dragStartView = _view;
        },
        onScaleUpdate: (d) {
          final start = _dragStartView ?? _view;
          // Pan: translate the focal-point delta into degrees.
          final s = start.scale(size);
          var v = start.copyWith(
            cx: start.cx - d.focalPointDelta.dx / s,
            cy: start.cy + d.focalPointDelta.dy / s,
          );
          // Pinch zoom around the focal point.
          if (d.scale != 1.0) {
            v = v.zoomedAt(d.scale, d.localFocalPoint, size);
          }
          _dragStartView = v; // accumulate for incremental deltas
          _setView(v, size);
        },
        onScaleEnd: (_) => _dragStartView = null,
        child: RepaintBoundary(
          child: CustomPaint(
            size: size,
            painter: GeoMapPainter(
              view: _view,
              style: style,
              features: _features,
              channels: channels,
              heatmap: _heatmap,
              daynight: _daynight,
              grid: _grid,
              hoveredGeohash: _hoveredGeohash,
              repaint: _ticker,
            ),
          ),
        ),
      ),
    );
  }

  Widget _topLeftControls(Size size) {
    return Positioned(
      top: 20,
      left: 20,
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
          _controlBtn('Reset View', onTap: () => _resetView(size)),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return Positioned(
      bottom: 20,
      left: 20,
      child: Row(
        children: [
          _controlBtn('Heat',
              active: _heatmap,
              onTap: () => setState(() => _heatmap = !_heatmap)),
          const SizedBox(width: 10),
          _controlBtn('Day / Night',
              active: _daynight,
              onTap: () => setState(() => _daynight = !_daynight)),
          const SizedBox(width: 10),
          _controlBtn('Geohash',
              active: _grid, onTap: () => setState(() => _grid = !_grid)),
        ],
      ),
    );
  }

  Widget _legend() {
    final nym = context.nym;
    return Positioned(
      bottom: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xB3000000), // rgba(0,0,0,0.7)
          border: Border.all(color: nym.glassBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: nym.primary, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            const Text('Active',
                style: TextStyle(fontSize: 10, color: Color(0xFFE0E0E0))),
            const SizedBox(width: 8),
            _windowGroup(nym),
          ],
        ),
      ),
    );
  }

  Widget _windowGroup(NymColors nym) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in kActiveWindowOptions)
            _windowBtn(h, h == _activeWindowHours, nym),
        ],
      ),
    );
  }

  Widget _windowBtn(int hours, bool active, NymColors nym) {
    return InkWell(
      onTap: () => setState(() => _activeWindowHours = hours),
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

  Widget _infoPanel(GeohashChannelPoint ch) {
    final nym = context.nym;
    final loc = decodeGeohash(ch.geohash);
    final latStr =
        '${loc.lat.abs().toStringAsFixed(2)}°${loc.lat >= 0 ? 'N' : 'S'}';
    final lngStr =
        '${loc.lng.abs().toStringAsFixed(2)}°${loc.lng >= 0 ? 'E' : 'W'}';
    return Positioned(
      top: 20,
      right: 20,
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(16, 16, 36, 16),
        decoration: BoxDecoration(
          color: const Color(0xB3000000), // rgba(0,0,0,0.7)
          border: Border.all(color: nym.glassBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${ch.geohash}',
                    style: TextStyle(
                      color: nym.primary,
                      fontSize: 14,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _selected = null),
                  child: Icon(Icons.close, size: 14, color: nym.textDim),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _infoRow('Location', '$latStr, $lngStr', nym),
            _infoRow('Recent messages', '${ch.messages}', nym),
            _infoRow('Status', ch.isJoined ? 'Joined' : 'Not joined', nym),
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
                    borderRadius: BorderRadius.circular(4),
                    side: BorderSide(color: nym.primaryA(0.3)),
                  ),
                ),
                child: const Text(
                  'JOIN CHANNEL',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, NymColors nym) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: nym.textDim)),
          Text(value, style: TextStyle(fontSize: 12, color: nym.text)),
        ],
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
    return SizedBox(
      width: width,
      child: Material(
        color: active ? nym.primaryA(0.18) : const Color(0xB3000000),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: width != null
                ? const EdgeInsets.symmetric(vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                  color: active ? nym.primaryA(0.5) : nym.glassBorder),
              borderRadius: BorderRadius.circular(4),
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
    );
  }
}

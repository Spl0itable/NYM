import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/nym_theme.dart';
import '../identity/panic_wipe.dart';
import 'geo_explore.dart';
import 'geo_projection.dart';
import 'street_bundle.dart';
import 'street_cache.dart';
import 'street_fetch.dart';
import 'street_labels.dart';
import 'street_mvt.dart';
import 'street_plan.dart';

const String kStreetAttribution = '© OpenStreetMap contributors';
const String kStreetCopyrightUrl = 'https://www.openstreetmap.org/copyright';
const String kStreetOdbl =
    'Street detail uses OpenStreetMap data, available under the ODbL 1.0; the extracts this app downloads are available under the same license.';
const String kStreetOdblUrl = 'https://opendatacommons.org/licenses/odbl/1-0/';
const String kStreetPrefKey = 'nym_street_detail';

const int kStreetBlockBytes = 50331648;
const int kStreetDecodedTiles = 64;
const int kStreetMemoryBundles = 12;
const double kStreetBlockPx = 256;

typedef StreetDecoder = Future<List<StreetTile?>> Function(List<StreetTileJob> jobs);

class StreetSession {
  static final List<int> sent = [];
  static int pausedUntil = 0;
  static bool stopped = false;

  static void reset() {
    sent.clear();
    pausedUntil = 0;
    stopped = false;
  }
}

class StreetPalette {
  const StreetPalette({
    required this.land,
    required this.water,
    required this.green,
    required this.landuse,
    required this.bld,
    required this.bldEdge,
    required this.casing,
    required this.road,
    required this.waterLabel,
  });

  final Color land;
  final Color water;
  final Color green;
  final Color landuse;
  final Color bld;
  final Color bldEdge;
  final Color casing;
  final Map<String, Color> road;
  final Color waterLabel;

  static const StreetPalette light = StreetPalette(
    land: Color(0xFFEEF2F4),
    water: Color(0xFFD6E8F1),
    green: Color(0xFFDCEBD9),
    landuse: Color(0xFFE8ECEF),
    bld: Color(0xFFDFE4E9),
    bldEdge: Color(0xFFCFD6DD),
    casing: Color(0xFFC3CDD6),
    road: {
      'hw': Color(0xFFF2DCAE),
      'major': Color(0xFFFBF3DD),
      'minor': Color(0xFFFFFFFF),
      'service': Color(0xFFFAFBFC),
      'path': Color(0xFFB9C4CD),
      'rail': Color(0xFFA6B1BB),
    },
    waterLabel: Color.fromRGBO(60, 110, 150, 0.9),
  );

  static const StreetPalette dark = StreetPalette(
    land: Color(0xFF1C2A39),
    water: Color(0xFF0A131E),
    green: Color(0xFF1D3A33),
    landuse: Color(0xFF223244),
    bld: Color(0xFF26374A),
    bldEdge: Color(0xFF2E4258),
    casing: Color(0xFF16222F),
    road: {
      'hw': Color(0xFF55708C),
      'major': Color(0xFF3E5873),
      'minor': Color(0xFF2F4458),
      'service': Color(0xFF2A3C50),
      'path': Color(0xFF2A3C50),
      'rail': Color(0xFF4A5B6D),
    },
    waterLabel: Color.fromRGBO(120, 170, 210, 0.85),
  );
}

const Map<String, List<double>> _widths = {
  'hw': [2, 5, 10],
  'major': [1.6, 4, 8],
  'minor': [0.8, 2.6, 5],
  'service': [0.5, 1.4, 3],
  'path': [0.5, 1, 1.5],
  'rail': [0.8, 1.2, 1.5],
  'river': [1, 2.5, 4],
  'stream': [0.5, 1, 1.5],
};

const List<String> _fillOrder = ['path', 'rail', 'service', 'minor', 'major', 'hw'];
const List<String> _cased = ['minor', 'major', 'hw'];
const Set<String> _areas = {'land', 'water', 'green', 'landuse', 'bld', 'river', 'stream'};

double streetWidthAt(String cls, double zv) {
  final t = _widths[cls];
  if (t == null) return 1;
  if (zv <= 14) return t[0];
  if (zv <= 16) return t[0] + (t[1] - t[0]) * (zv - 14) / 2;
  if (zv <= 18) return t[1] + (t[2] - t[1]) * (zv - 16) / 2;
  return t[2];
}

class _Block {
  _Block(this.image, this.e, this.lngW, this.latN, this.deg, this.light, this.bytes);
  final ui.Image image;
  final int e;
  final double lngW;
  final double latN;
  final double deg;
  final bool light;
  final int bytes;
}

class _PlacedLabel {
  _PlacedLabel(this.lng, this.lat, this.angle, this.fill, this.halo);
  final double lng;
  final double lat;
  final double angle;
  final TextPainter fill;
  final TextPainter halo;
}

class StreetStats {
  int paintUs = 0;
  int paints = 0;
  int maxPaintUs = 0;
  int rasterUs = 0;
  int rasterBlocks = 0;
  int placeUs = 0;
  int pathUs = 0;
}

class StreetLayer extends ChangeNotifier {
  StreetLayer({
    StreetFetcher? fetcher,
    StreetStore? store,
    int Function()? now,
    StreetDecoder? decoder,
  })  : _fetcher = fetcher ?? HttpStreetFetcher(),
        _store = store ?? StreetFileCache(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _decoder = decoder ?? decodeStreetTiles {
    unawaited(_store.sweep().catchError((_) {}));
  }

  final StreetFetcher _fetcher;
  final StreetStore _store;
  final int Function() _now;
  final StreetDecoder _decoder;

  final ValueNotifier<bool> attribution = ValueNotifier<bool>(false);

  bool _enabled = true;
  bool _paused = false;
  bool _disposed = false;
  bool _settled = false;
  int _gen = 0;
  StreetPlan plan = StreetPlan.none;
  (double, double, double, double, double)? _lastView;
  Timer? _settleTimer;
  Timer? _waitTimer;
  Timer? _idleTimer;
  bool _moving = false;

  final LinkedHashMap<String, StreetBundle> _bundles = LinkedHashMap();
  final Set<String> _checked = {};
  final Set<String> _reading = {};
  final Set<String> _inflight = {};
  final Map<String, int> _neg = {};

  final LinkedHashMap<String, StreetTile?> _tiles = LinkedHashMap();
  final Set<String> _decoding = {};
  final LinkedHashMap<String, _Block> _blocks = LinkedHashMap();
  int _blockBytes = 0;
  final List<(String, int, double, double, double)> _want = [];
  bool _rasterQueued = false;
  final Expando<ui.Path> _paths = Expando<ui.Path>();

  List<_PlacedLabel> _labels = const [];
  double? _labelZoom;
  bool _needPlace = false;
  final Map<String, TextPainter> _text = {};
  bool _drewLast = false;
  List<StreetBox> _labelBoxes = const [];
  final StreetStats stats = StreetStats();

  List<String> get loadedCells => _bundles.keys.toList()..sort();
  bool get enabled => _enabled;
  int get blockCount => _blocks.length;
  int get decodedTiles => _tiles.length;
  int get labelCount => _labels.length;
  bool get drew => _drewLast;
  List<StreetBox> get labelBoxes => _labelBoxes;

  void setEnabled(bool on) {
    if (_enabled == on) return;
    _enabled = on;
    _lastView = null;
    if (!on) {
      _stop();
      plan = StreetPlan.none;
      _labels = const [];
      _setAttribution(false);
    }
    notifyListeners();
  }

  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    if (paused) {
      _stop();
      return;
    }
    _settleTimer?.cancel();
    if (plan.draw) {
      _settleTimer = Timer(Duration(milliseconds: kStreet.settleMs), _onSettle);
    }
  }

  void _stop() {
    _settleTimer?.cancel();
    _waitTimer?.cancel();
    _idleTimer?.cancel();
    _settled = false;
    _gen++;
    _inflight.clear();
    _fetcher.abort();
  }

  void update({
    required double cx,
    required double cy,
    required double pxPerDeg,
    required double width,
    required double height,
  }) {
    if (_disposed) return;
    final v = (cx, cy, pxPerDeg, width, height);
    if (v == _lastView) return;
    _lastView = v;
    _settled = false;
    _moving = true;
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 150), () {
      _moving = false;
      if (_want.isNotEmpty && !_disposed) notifyListeners();
    });
    plan = planStreetCells(
        cx: cx,
        cy: cy,
        pxPerDeg: pxPerDeg,
        width: width,
        height: height,
        on: _enabled);
    _settleTimer?.cancel();
    if (!plan.draw) return;
    for (final c in plan.cells) {
      if (!_bundles.containsKey(c)) _read(c);
    }
    _settleTimer = Timer(Duration(milliseconds: kStreet.settleMs), _onSettle);
  }

  void _onSettle() {
    if (_disposed) return;
    _settled = true;
    _needPlace = true;
    _pump();
    notifyListeners();
  }

  Future<void> _read(String cell) async {
    if (_checked.contains(cell) || !_reading.add(cell)) return;
    Uint8List? bytes;
    int? neg;
    try {
      neg = await _store.negativeUntil(cell);
      if (neg == null) bytes = await _store.read(cell);
    } catch (_) {}
    _reading.remove(cell);
    if (_disposed) return;
    if (neg != null) _neg[cell] = neg;
    if (bytes != null) {
      try {
        _addBundle(parseStreetBundle(bytes, expectCell: cell));
      } catch (_) {}
    }
    _checked.add(cell);
    _pump();
  }

  void _addBundle(StreetBundle b) {
    _bundles.remove(b.cell);
    _bundles[b.cell] = b;
    while (_bundles.length > kStreetMemoryBundles) {
      final old = _bundles.keys.firstWhere((k) => !plan.cells.contains(k),
          orElse: () => _bundles.keys.first);
      _bundles.remove(old);
      _dropBlocksFor(old);
    }
    _dropBlocksFor(b.cell);
    _needPlace = true;
    notifyListeners();
  }

  void _dropBlocksFor(String cell) {
    final c = streetCellBounds(cell);
    final drop = <String>[];
    _blocks.forEach((k, b) {
      if (b.lngW < c.e && b.lngW + b.deg > c.w && b.latN > c.s && b.latN - b.deg < c.n) {
        drop.add(k);
      }
    });
    for (final k in drop) {
      _removeBlock(k);
    }
  }

  void _removeBlock(String k) {
    final b = _blocks.remove(k);
    if (b == null) return;
    _blockBytes -= b.bytes;
    b.image.dispose();
  }

  void _pump() {
    if (_disposed || !_enabled || _paused || !_settled || !plan.fetch) return;
    if (StreetSession.stopped) return;
    if (PanicWipe.inProgress) {
      _stop();
      return;
    }
    final now = _now();
    if (now < StreetSession.pausedUntil) {
      _waitTimer?.cancel();
      _waitTimer = Timer(Duration(milliseconds: StreetSession.pausedUntil - now), _pump);
      return;
    }
    StreetSession.sent.removeWhere((t) => now - t >= 60000);
    final missing = [
      for (final c in plan.cells)
        if (_checked.contains(c) &&
            !_bundles.containsKey(c) &&
            !_inflight.contains(c) &&
            (_neg[c] ?? 0) <= now)
          c
    ];
    if (missing.isEmpty) return;
    final r = nextStreetFetches(
        sent: StreetSession.sent, inflight: _inflight.length, missing: missing, now: now);
    for (final c in r.start) {
      _fetch(c);
    }
    if (r.waitMs > 0) {
      _waitTimer?.cancel();
      _waitTimer = Timer(Duration(milliseconds: r.waitMs), _pump);
    }
  }

  void _fetch(String cell) {
    final gen = _gen;
    _inflight.add(cell);
    StreetSession.sent.add(_now());
    _fetcher.fetch(cell).then((r) => _onResult(cell, r, gen),
        onError: (_) => _onResult(cell, const StreetFetchResult(0, null), gen));
  }

  void _negative(String cell, int ms) {
    final until = _now() + ms;
    _neg[cell] = until;
    unawaited(_store.putNegative(cell, until).catchError((_) {}));
  }

  void _onResult(String cell, StreetFetchResult r, int gen) {
    if (_disposed || gen != _gen || r.aborted) return;
    if (PanicWipe.inProgress) {
      _stop();
      return;
    }
    _inflight.remove(cell);
    final a = streetStatusAction(r.status);
    switch (a.kind) {
      case StreetAction.ok:
        final bytes = r.bytes;
        StreetBundle? b;
        if (bytes != null) {
          try {
            b = parseStreetBundle(bytes, expectCell: cell);
          } catch (_) {}
        }
        if (b == null || bytes == null) {
          _negative(cell, kStreet.tooLargeRetryMs);
        } else {
          _addBundle(b);
          unawaited(_store.write(cell, bytes).catchError((_) {}));
        }
      case StreetAction.negative:
        _negative(cell, a.ms);
      case StreetAction.pause:
        StreetSession.pausedUntil = _now() + a.ms;
      case StreetAction.stop:
        StreetSession.stopped = true;
    }
    _pump();
  }

  List<StreetBundle> _planBundles() => [
        for (final c in plan.cells)
          if (_bundles[c] != null) _bundles[c]!
      ];

  final Expando<List<(StreetBundleEntry, double, double, double, double)>> _bounds =
      Expando();

  List<(StreetBundleEntry, double, double, double, double)> _boundsOf(StreetBundle b) =>
      _bounds[b] ??= [
        for (final t in b.tiles)
          (
            t,
            t.x / (1 << t.z) * 360 - 180,
            (t.x + 1) / (1 << t.z) * 360 - 180,
            streetTileLat(t.y.toDouble(), t.z),
            streetTileLat(t.y + 1.0, t.z),
          )
      ];

  Map<String, (StreetBundle, StreetBundleEntry)> _tilesIn(
      double w, double n, double e, double s, double bucketZv) {
    final out = <String, (StreetBundle, StreetBundleEntry)>{};
    for (final b in _planBundles()) {
      final tz = streetTileZoomFor(bucketZv, b.availableZooms);
      if (tz == null) continue;
      for (final (t, tw, te, tn, ts) in _boundsOf(b)) {
        if (t.z != tz || t.missing) continue;
        if (te <= w || tw >= e || tn <= s || ts >= n) continue;
        final prev = out[t.key];
        if (prev == null || prev.$1.level > b.level) out[t.key] = (b, t);
      }
    }
    return out;
  }

  bool paint(Canvas canvas, Size size, GeoView view,
      {required bool light, required double dpr}) {
    if (!_enabled || !plan.draw || _bundles.isEmpty || size.isEmpty) {
      _setAttribution(false);
      return false;
    }
    final clock = Stopwatch()..start();
    final s = view.scale(size);
    final e = streetBucketExp(s);
    final bs = streetBucketScaleOf(e);
    final deg = kStreetBlockPx / bs;
    final w = view.cx - size.width / 2 / s, east = view.cx + size.width / 2 / s;
    final n = view.cy + size.height / 2 / s, south = view.cy - size.height / 2 / s;
    final bx0 = ((w + 180) / deg).floor(), bx1 = ((east + 180) / deg).floor();
    final by0 = ((90 - n) / deg).floor(), by1 = ((90 - south) / deg).floor();
    final bucketZv = streetZvOf(bs);
    final p = Paint()
      ..filterQuality = FilterQuality.low
      ..isAntiAlias = false;
    var drew = false;
    void blit(_Block b) {
      final tl = view.project(b.lngW, b.latN, size);
      final br = view.project(b.lngW + b.deg, b.latN - b.deg, size);
      canvas.drawImageRect(
          b.image,
          Rect.fromLTWH(0, 0, b.image.width.toDouble(), b.image.height.toDouble()),
          Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy),
          p);
      drew = true;
    }

    for (final b in _blocks.values) {
      if (b.light != light || (b.e - e).abs() != 1) continue;
      if (b.lngW >= east || b.lngW + b.deg <= w || b.latN <= south || b.latN - b.deg >= n) {
        continue;
      }
      blit(b);
    }
    _want.clear();
    final used = <String>[];
    for (var by = by0; by <= by1; by++) {
      for (var bx = bx0; bx <= bx1; bx++) {
        final lngW = -180 + bx * deg, latN = 90 - by * deg;
        final key = '${light ? 'l' : 'd'}|$e|$bx|$by';
        final b = _blocks.remove(key);
        if (b != null) {
          _blocks[key] = b;
          used.add(key);
          blit(b);
          continue;
        }
        if (_tilesIn(lngW, latN, lngW + deg, latN - deg, bucketZv).isEmpty) continue;
        _want.add((key, e, lngW, latN, deg));
      }
    }
    _trimBlocks(used.toSet());
    _drewLast = drew;
    final us = clock.elapsedMicroseconds;
    stats
      ..paintUs += us
      ..paints += 1
      ..maxPaintUs = us > stats.maxPaintUs ? us : stats.maxPaintUs;
    _setAttribution(drew);
    if (_want.isNotEmpty) _queueRaster(light, capGeoDpr(dpr));
    return drew;
  }

  void _trimBlocks(Set<String> keep) {
    while (_blockBytes > kStreetBlockBytes) {
      final k = _blocks.keys.firstWhere((k) => !keep.contains(k), orElse: () => '');
      if (k.isEmpty) break;
      _removeBlock(k);
    }
  }

  void _setAttribution(bool on) {
    if (attribution.value == on) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) attribution.value = on && _drewLast && _enabled;
    });
  }

  void _queueRaster(bool light, double dpr) {
    if (_rasterQueued) return;
    _rasterQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rasterQueued = false;
      if (_disposed) return;
      _rasterize(light, dpr, _moving ? 2 : 1 << 20, 8000);
    });
  }

  void _rasterize(bool light, double dpr, int maxBlocks, int budgetUs) {
    final clock = Stopwatch()..start();
    var made = 0;
    final jobs = <String, StreetTileJob>{};
    for (final (key, e, lngW, latN, deg) in [..._want]) {
      if (made >= maxBlocks || clock.elapsedMicroseconds > budgetUs) break;
      if (_blocks.containsKey(key)) continue;
      final bs = streetBucketScaleOf(e);
      final tiles = _tilesIn(lngW, latN, lngW + deg, latN - deg, streetZvOf(bs));
      final ready = <StreetTile>[];
      var waiting = false;
      for (final entry in tiles.entries) {
        if (_tiles.containsKey(entry.key)) {
          final t = _tiles.remove(entry.key);
          _tiles[entry.key] = t;
          if (t != null) ready.add(t);
        } else {
          waiting = true;
          final (b, te) = entry.value;
          if (!_decoding.contains(entry.key)) {
            jobs[entry.key] = StreetTileJob(z: te.z, x: te.x, y: te.y, gz: b.tileBytes(te));
          }
        }
      }
      if (waiting) continue;
      final t0 = clock.elapsedMicroseconds;
      final img = _rasterBlock(ready, lngW, latN, bs, dpr, light, streetZvOf(bs));
      stats
        ..rasterUs += clock.elapsedMicroseconds - t0
        ..rasterBlocks += 1;
      final bytes = img.width * img.height * 4;
      _blocks[key] = _Block(img, e, lngW, latN, deg, light, bytes);
      _blockBytes += bytes;
      made++;
    }
    if (jobs.isNotEmpty) _decode(jobs);
    if (made > 0) notifyListeners();
  }

  void _decode(Map<String, StreetTileJob> jobs) {
    _decoding.addAll(jobs.keys);
    final gen = _gen;
    _decoder(jobs.values.toList()).then((out) {
      _decoding.removeAll(jobs.keys);
      if (_disposed || gen != _gen) return;
      var i = 0;
      for (final k in jobs.keys) {
        _tiles[k] = out[i++];
      }
      while (_tiles.length > kStreetDecodedTiles) {
        _tiles.remove(_tiles.keys.first);
      }
      _needPlace = true;
      notifyListeners();
    }, onError: (_) {
      _decoding.removeAll(jobs.keys);
    });
  }

  ui.Path _path(StreetGroup g) {
    final cached = _paths[g];
    if (cached != null) return cached;
    final clock = Stopwatch()..start();
    final path = ui.Path();
    final pts = g.pts, parts = g.parts;
    for (var k = 0; k + 1 < parts.length; k++) {
      final a = parts[k], b = parts[k + 1];
      if (b - a < 2) continue;
      path.moveTo(pts[2 * a], pts[2 * a + 1]);
      for (var i = a + 1; i < b; i++) {
        path.lineTo(pts[2 * i], pts[2 * i + 1]);
      }
      if (g.poly) path.close();
    }
    _paths[g] = path;
    stats.pathUs += clock.elapsedMicroseconds;
    return path;
  }

  ui.Image _rasterBlock(List<StreetTile> tiles, double lngW, double latN, double k,
      double dpr, bool light, double zv) {
    final px = (kStreetBlockPx * dpr).round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.clipRect(Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()));
    c.scale(dpr);
    paintStreetTiles(c, tiles, lngW, latN, k, light, zv, _path);
    final pic = rec.endRecording();
    final img = pic.toImageSync(px, px);
    pic.dispose();
    return img;
  }

  void paintLabels(Canvas canvas, Size size, GeoView view, List<StreetBox> blocked,
      {required Color fill, required Color halo, required bool light}) {
    if (!_enabled || !plan.draw || !_drewLast) return;
    if (_needPlace && _settled) {
      _place(size, view, blocked, fill, halo, light);
    }
    if (_labelZoom != view.zoom) return;
    for (final l in _labels) {
      final p = view.project(l.lng, l.lat, size);
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(l.angle);
      final o = Offset(-l.fill.width / 2, -l.fill.height / 2);
      l.halo.paint(canvas, o);
      l.fill.paint(canvas, o);
      canvas.restore();
    }
  }

  TextPainter _mk(String name, double fs, bool italic, Paint? fg, Color? color) =>
      TextPainter(
          text: TextSpan(
            text: name,
            style: TextStyle(
              fontFamily: kSansFont,
              fontSize: fs,
              fontWeight: FontWeight.w500,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              color: color,
              foreground: fg,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();

  TextPainter _textFor(String name, double fs, bool italic, Color fill) {
    final key = '$name|$fs|$italic|${fill.toARGB32()}';
    final hit = _text[key];
    if (hit != null) return hit;
    if (_text.length > 2000) _text.clear();
    return _text[key] = _mk(name, fs, italic, null, fill);
  }

  TextPainter _haloFor(String name, double fs, bool italic, Color halo) {
    final key = 'h|$name|$fs|$italic|${halo.toARGB32()}';
    final hit = _text[key];
    if (hit != null) return hit;
    return _text[key] = _mk(
        name,
        fs,
        italic,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..color = halo,
        null);
  }

  void _place(Size size, GeoView view, List<StreetBox> blocked, Color fill, Color halo,
      bool light) {
    _needPlace = false;
    final clock = Stopwatch()..start();
    final s = view.scale(size);
    final zv = streetZvOf(s);
    final fs = zv >= 16 ? 12.0 : 11.0;
    final waterFill = (light ? StreetPalette.light : StreetPalette.dark).waterLabel;
    final w = view.cx - size.width / 2 / s, e = view.cx + size.width / 2 / s;
    final n = view.cy + size.height / 2 / s, so = view.cy - size.height / 2 / s;
    final tiles = _tilesIn(w, n, e, so, zv);
    final cands = <(int, double, StreetLabelCandidate, double, TextPainter, bool)>[];
    for (final k in tiles.keys) {
      final t = _tiles[k];
      if (t == null) continue;
      final x0 = w - t.lngW, x1 = e - t.lngW, y0 = t.latN - n, y1 = t.latN - so;
      for (final src in t.labels) {
        final pp = src.pts;
        var minX = double.infinity, maxX = -double.infinity;
        var minY = double.infinity, maxY = -double.infinity;
        for (var i = 0; i + 1 < pp.length; i += 2) {
          if (pp[i] < minX) minX = pp[i];
          if (pp[i] > maxX) maxX = pp[i];
          if (pp[i + 1] < minY) minY = pp[i + 1];
          if (pp[i + 1] > maxY) maxY = pp[i + 1];
        }
        if (maxX < x0 || minX > x1 || maxY < y0 || minY > y1) continue;
        final water = src.rank >= 5;
        final fp = _textFor(src.name, fs, water, water ? waterFill : fill);
        final tw = fp.width, th = fp.height;
        if (src.point) {
          final p = view.project(t.lngW + src.pts[0], t.latN - src.pts[1], size);
          if (p.dx < 0 || p.dy < 0 || p.dx > size.width || p.dy > size.height) continue;
          cands.add((
            src.rank,
            0,
            StreetLabelCandidate(
                name: src.name,
                x: p.dx,
                y: p.dy,
                boxes: streetLabelBoxes(p.dx, p.dy, 0, tw, th)),
            0,
            fp,
            water,
          ));
          continue;
        }
        final pts = Float64List(src.pts.length);
        for (var i = 0; i + 1 < src.pts.length; i += 2) {
          pts[i] = (t.lngW + src.pts[i] - view.cx) * s + size.width / 2;
          pts[i + 1] = (view.cy - t.latN + src.pts[i + 1]) * s + size.height / 2;
        }
        final ll = lineLabel(pts, tw, th, size.width, size.height);
        if (ll == null) continue;
        final len = ll.boxes.length.toDouble();
        cands.add((
          src.rank,
          -len,
          StreetLabelCandidate(name: src.name, x: ll.x, y: ll.y, boxes: ll.boxes),
          ll.angle,
          fp,
          water,
        ));
      }
    }
    cands.sort((a, b) {
      final r = a.$1.compareTo(b.$1);
      return r != 0 ? r : a.$2.compareTo(b.$2);
    });
    final idx = placeLineLabels([for (final c in cands) c.$3], blocked);
    _labels = [
      for (final i in idx)
        () {
          final c = cands[i];
          final u = view.unproject(c.$3.x, c.$3.y, size);
          return _PlacedLabel(u.lng, u.lat, c.$4, c.$5,
              _haloFor(c.$3.name, fs, c.$6, halo));
        }()
    ];
    _labelBoxes = [for (final i in idx) ...cands[i].$3.boxes];
    _labelZoom = view.zoom;
    stats.placeUs = clock.elapsedMicroseconds;
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    for (final b in _blocks.values) {
      b.image.dispose();
    }
    _blocks.clear();
    attribution.dispose();
    super.dispose();
  }
}

void paintStreetTiles(Canvas c, List<StreetTile> tiles, double lngW, double latN,
    double k, bool light, double zv, ui.Path Function(StreetGroup g) pathOf) {
  final pal = light ? StreetPalette.light : StreetPalette.dark;
  final river = light ? const Color(0xB35A96BE) : const Color(0x8C4678A0);
  final unit = 1 / k;
  bool keep(StreetGroup g) => _areas.contains(g.cls) || zv >= 15 || g.mz <= zv + 1;
  void each(void Function(StreetGroup g) fn) {
    for (final t in tiles) {
      c.save();
      c.translate((t.lngW - lngW) * k, (latN - t.latN) * k);
      c.scale(k);
      for (final g in t.groups) {
        if (keep(g)) fn(g);
      }
      c.restore();
    }
  }

  final fill = Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
  for (final (cls, color) in [
    ('land', pal.land),
    ('landuse', pal.landuse),
    ('green', pal.green),
    ('water', pal.water),
  ]) {
    fill.color = color;
    each((g) {
      if (g.cls == cls && g.poly) c.drawPath(pathOf(g), fill);
    });
  }
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  stroke.color = river;
  for (final cls in ['river', 'stream']) {
    stroke.strokeWidth = streetWidthAt(cls, zv) * unit;
    each((g) {
      if (g.cls == cls && !g.poly) c.drawPath(pathOf(g), stroke);
    });
  }
  fill.color = pal.bld;
  each((g) {
    if (g.cls == 'bld') c.drawPath(pathOf(g), fill);
  });
  if (zv >= 16.5) {
    stroke
      ..color = pal.bldEdge
      ..strokeWidth = 0.5 * unit;
    each((g) {
      if (g.cls == 'bld') c.drawPath(pathOf(g), stroke);
    });
  }
  void roads(int st, bool casing, double alpha) {
    for (final cls in casing ? _cased : _fillOrder) {
      final base = casing ? pal.casing : pal.road[cls]!;
      stroke
        ..color = base.withValues(alpha: base.a * alpha)
        ..strokeWidth = (streetWidthAt(cls, zv) + (casing ? 1.5 : 0)) * unit;
      each((g) {
        if (g.cls == cls && g.st == st && !g.poly) c.drawPath(pathOf(g), stroke);
      });
    }
  }

  roads(1, false, 0.5);
  if (zv >= 15) roads(0, true, 1);
  roads(0, false, 1);
  roads(2, true, 1);
  roads(2, false, 1);
}

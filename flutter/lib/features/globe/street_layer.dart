import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/nym_theme.dart';
import '../identity/panic_wipe.dart';
import 'geo_explore.dart';
import 'geo_projection.dart';
import 'street_cache.dart';
import 'street_fetch.dart';
import 'street_labels.dart';
import 'street_mvt.dart';
import 'street_plan.dart';

const String kStreetAttribution = '© OpenStreetMap contributors';
const String kStreetCopyrightUrl = 'https://www.openstreetmap.org/copyright';
const String kStreetPrefKey = 'nym_street_detail';

const int kStreetBlockBytes = 50331648;
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
    this.lowRoad = const {},
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
  final Map<String, Color> lowRoad;

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
    lowRoad: {'hw': Color(0xFFE8C58A), 'major': Color(0xFFF0D9A8)},
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

const List<String> _fillOrder = ['path', 'rail', 'service', 'minor', 'major', 'hw'];
const List<String> _cased = ['minor', 'major', 'hw'];

class _Block {
  _Block(this.image, this.e, this.light, this.bytes, this.want);
  final ui.Image image;
  final int e;
  final bool light;
  final int bytes;
  final _Want want;
  double get lngW => want.lngW;
  double get latN => want.latN;
  double get deg => want.deg;
}

class _Want {
  _Want(this.key, this.e, this.tz, this.lngW, this.latN, this.deg, this.items, this.pending,
      this.fallback);
  final String key;
  final int e;
  final int tz;
  final double lngW;
  final double latN;
  final double deg;
  final List<(String, StreetTileId, StreetTileId)> items;
  final Set<String> pending;
  final bool fallback;
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

StreetTileId? _idOf(String key) {
  final p = key.split('/');
  if (p.length != 3) return null;
  final z = int.tryParse(p[0]), x = int.tryParse(p[1]), y = int.tryParse(p[2]);
  if (z == null || x == null || y == null) return null;
  return (z: z, x: x, y: y);
}

bool _validGz(Uint8List b) =>
    b.isEmpty || (b.length <= kStreet.maxBodyBytes && b.length > 2 && b[0] == 0x1f && b[1] == 0x8b);

int? _metaBuild(Uint8List? b) {
  if (b == null) return null;
  try {
    final j = jsonDecode(utf8.decode(b));
    if (j is Map && j['v'] == 2 && j['build'] is int && (j['build'] as int) > 0) {
      return j['build'] as int;
    }
  } catch (_) {}
  return null;
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
    StreetHalt.add(_halt);
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
  bool _halted = false;
  bool _settled = false;
  int _gen = 0;
  StreetPlan plan = StreetPlan.none;
  (double, double, double, double, double)? _lastView;
  Timer? _settleTimer;
  Timer? _waitTimer;
  Timer? _idleTimer;
  bool _moving = false;

  int? _build;
  int _metaAt = 0;
  bool _metaRead = false;
  bool _metaLoading = false;
  bool _metaSettled = false;

  final LinkedHashMap<String, Uint8List> _gz = LinkedHashMap();
  int _gzBytes = 0;
  final Set<String> _checked = {};
  final Set<String> _reading = {};
  final Set<String> _inflight = {};
  final Map<String, int> _neg = {};

  final LinkedHashMap<String, StreetTile?> _tiles = LinkedHashMap();
  final Set<String> _decoding = {};
  final LinkedHashMap<String, _Block> _blocks = LinkedHashMap();
  int _blockBytes = 0;
  final List<_Want> _want = [];
  bool _rasterQueued = false;
  final Expando<ui.Path> _paths = Expando<ui.Path>();

  List<_PlacedLabel> _labels = const [];
  double? _labelZoom;
  bool _needPlace = false;
  final Map<String, TextPainter> _text = {};
  bool _drewLast = false;
  List<StreetBox> _labelBoxes = const [];
  final StreetStats stats = StreetStats();

  int? get build => _build;
  List<String> get loadedTiles => _gz.keys.toList()..sort();
  bool get enabled => _enabled;
  int get blockCount => _blocks.length;
  int get provisionalBlocks => _blocks.values.where((b) => b.want.fallback).length;
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
      _drewLast = false;
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

  void _halt() {
    if (_halted) return;
    _halted = true;
    _stop();
    _store.close();
    _gz.clear();
    _gzBytes = 0;
    _tiles.clear();
    _checked.clear();
    _reading.clear();
    _neg.clear();
    for (final k in [..._blocks.keys]) {
      _removeBlock(k);
    }
    _want.clear();
    _labels = const [];
    _needPlace = false;
    plan = StreetPlan.none;
    _drewLast = false;
    if (_disposed) return;
    attribution.value = false;
    notifyListeners();
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
    if (_disposed || _halted) return;
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
    plan = planStreetTiles(
        cx: cx,
        cy: cy,
        pxPerDeg: pxPerDeg,
        width: width,
        height: height,
        on: _enabled);
    _settleTimer?.cancel();
    if (!plan.draw && _inflight.isEmpty) return;
    _settleTimer = Timer(Duration(milliseconds: kStreet.settleMs), _onSettle);
  }

  void _onSettle() {
    if (_disposed || _halted) return;
    _settled = true;
    _needPlace = true;
    _syncWanted();
    notifyListeners();
  }

  void _syncWanted() {
    if (_disposed || _halted || !_enabled || _paused || !_settled) return;
    if (PanicWipe.inProgress) {
      _stop();
      return;
    }
    final b = _build;
    if (b != null && _inflight.isNotEmpty) {
      final wanted = [for (final t in plan.tiles) streetCacheKey(b, t.z, t.x, t.y)];
      for (final k in streetCancelSet([for (final i in _inflight) '$b/$i'], wanted)) {
        _inflight.remove(k.substring(k.indexOf('/') + 1));
        _fetcher.cancel(k);
      }
    }
    if (!plan.draw) return;
    for (final t in plan.tiles) {
      final k = streetTileKey(t);
      final g = _gz.remove(k);
      if (g != null) _gz[k] = g;
    }
    if (!_metaOk()) {
      unawaited(_loadMeta());
      return;
    }
    for (final t in plan.tiles) {
      final k = streetTileKey(t);
      if (!_gz.containsKey(k) && !_checked.contains(k)) unawaited(_read(k));
    }
    _pump();
  }

  bool _metaOk() =>
      _build != null && (_metaSettled || _now() - _metaAt < kStreet.metaTtlMs);

  Future<void> _loadMeta() async {
    if (_metaLoading) return;
    _metaLoading = true;
    try {
      await _metaStep();
    } catch (_) {
    } finally {
      _metaLoading = false;
    }
    if (_disposed || _halted) return;
    if (_metaOk()) {
      _syncWanted();
    } else {
      _pump();
    }
  }

  Future<void> _metaStep() async {
    if (!_metaRead) {
      _metaRead = true;
      StreetMeta? m;
      try {
        m = await _store.readMeta();
      } catch (_) {}
      if (m != null && _build == null) {
        _build = m.build;
        _metaAt = m.fetchedAt;
      }
    }
    if (_disposed || _halted || PanicWipe.inProgress || _metaOk()) return;
    final now = _now();
    if (StreetSession.stopped || now < StreetSession.pausedUntil) {
      if (_build != null) _metaSettled = true;
      return;
    }
    final r = await _fetcher.fetchMeta();
    if (_disposed || _halted || r.aborted || PanicWipe.inProgress) return;
    final nb = r.status == 200 ? _metaBuild(r.bytes) : null;
    if (nb != null) {
      _adoptBuild(nb);
    } else if (_build != null) {
      _metaSettled = true;
    } else if (streetStatusAction(r.status == 200 ? 503 : r.status).kind == StreetAction.stop) {
      StreetSession.stopped = true;
    } else {
      StreetSession.pausedUntil = _now() + kStreet.unavailableRetryMs;
    }
  }

  void _adoptBuild(int nb) {
    _metaAt = _now();
    _metaSettled = true;
    unawaited(_store.writeMeta(nb, _metaAt).catchError((_) {}));
    if (_build == nb) return;
    final had = _build != null;
    _build = nb;
    if (_inflight.isNotEmpty) {
      _gen++;
      _inflight.clear();
      _fetcher.abort();
    }
    _gz.clear();
    _gzBytes = 0;
    _tiles.clear();
    _checked.clear();
    _neg.clear();
    if (had) {
      for (final k in [..._blocks.keys]) {
        _removeBlock(k);
      }
    }
    unawaited(_store.dropOtherBuilds(nb).catchError((_) {}));
  }

  Future<void> _read(String key) async {
    final b = _build;
    if (b == null || _checked.contains(key) || !_reading.add(key)) return;
    Uint8List? bytes;
    int? neg;
    try {
      neg = await _store.negativeUntil('$b/$key');
      if (neg == null) bytes = await _store.read('$b/$key');
    } catch (_) {}
    _reading.remove(key);
    if (_disposed || _halted || b != _build) return;
    if (neg != null) _neg[key] = neg;
    if (bytes != null && _validGz(bytes)) _addTile(key, bytes);
    _checked.add(key);
    if (_reading.isEmpty) _pump();
  }

  void _addTile(String key, Uint8List bytes) {
    final old = _gz.remove(key);
    if (old != null) _gzBytes -= old.length;
    _gz[key] = bytes;
    _gzBytes += bytes.length;
    _tiles.remove(key);
    if (_gzBytes > kStreet.memGzipBytes) {
      final keep = {for (final t in plan.tiles) streetTileKey(t)};
      for (final k in [..._gz.keys]) {
        if (_gzBytes <= kStreet.memGzipBytes || _gz.length <= 1) break;
        if (keep.contains(k) || k == key) continue;
        _gzBytes -= _gz.remove(k)!.length;
        _tiles.remove(k);
        _checked.remove(k);
      }
    }
    for (final e in [..._blocks.entries]) {
      if (e.value.want.pending.contains(key)) _removeBlock(e.key);
    }
    _needPlace = true;
    notifyListeners();
  }

  void _removeBlock(String k) {
    final b = _blocks.remove(k);
    if (b == null) return;
    _blockBytes -= b.bytes;
    b.image.dispose();
  }

  void _pump() {
    if (_disposed || _halted || !_enabled || _paused || !_settled || !plan.draw) return;
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
    if (!_metaOk()) {
      unawaited(_loadMeta());
      return;
    }
    final b = _build!;
    StreetSession.sent.removeWhere((t) => now - t >= kStreet.windowMs);
    final queue = <String>[];
    for (final t in plan.tiles) {
      final k = streetTileKey(t);
      if (_checked.contains(k) &&
          !_gz.containsKey(k) &&
          !_inflight.contains(k) &&
          (_neg[k] ?? 0) <= now) {
        queue.add(k);
      }
    }
    if (queue.isEmpty) return;
    final r = nextStreetTileFetches(
        queue: queue, inflight: _inflight.length, sent: StreetSession.sent, now: now);
    for (final k in r.start) {
      _fetch(b, k);
    }
    if (r.waitMs > 0) {
      _waitTimer?.cancel();
      _waitTimer = Timer(Duration(milliseconds: r.waitMs), _pump);
    }
  }

  void _fetch(int b, String key) {
    final id = _idOf(key);
    if (id == null) return;
    final gen = _gen;
    _inflight.add(key);
    final pending = _fetcher.fetchTile(b, id);
    StreetSession.sent.add(_now());
    pending.then((r) => _onResult(b, key, r, gen),
        onError: (_) => _onResult(b, key, const StreetFetchResult(0, null), gen));
  }

  void _negative(int b, String key, int ms) {
    final until = _now() + ms;
    _neg[key] = until;
    unawaited(_store.putNegative('$b/$key', until).catchError((_) {}));
  }

  void _onResult(int b, String key, StreetFetchResult r, int gen) {
    if (_disposed || _halted || gen != _gen || r.aborted || b != _build) return;
    if (PanicWipe.inProgress) {
      _stop();
      return;
    }
    if (!_inflight.remove(key)) return;
    final body = r.status == 404 && r.bytes != null
        ? utf8.decode(r.bytes!, allowMalformed: true)
        : null;
    final a = streetStatusAction(r.status, body);
    switch (a.kind) {
      case StreetAction.ok:
        final bytes = r.bytes ?? Uint8List(0);
        if (!_validGz(bytes)) {
          _negative(b, key, kStreet.malformedRetryMs);
        } else {
          _addTile(key, bytes);
          unawaited(_store.write('$b/$key', bytes).catchError((_) {}));
        }
      case StreetAction.rebuild:
        _adoptBuild(a.build!);
        _syncWanted();
        return;
      case StreetAction.negative:
        _negative(b, key, a.ms);
      case StreetAction.pause:
        StreetSession.pausedUntil = _now() + a.ms;
      case StreetAction.stop:
        StreetSession.stopped = true;
    }
    _pump();
  }

  bool _has(StreetTileId t) => _gz.containsKey(streetTileKey(t));

  _Want? _blockWant(String key, int e, int tz, double lngW, double latN, double deg) {
    final r = streetTileRange(lngW, lngW + deg, latN - deg, latN, tz);
    if (r == null) return null;
    final items = <(String, StreetTileId, StreetTileId)>[];
    final pending = <String>{};
    var fallback = false;
    for (var y = r.y0; y <= r.y1; y++) {
      for (var x = r.x0; x <= r.x1; x++) {
        final want = (z: tz, x: x, y: y);
        final wk = streetTileKey(want);
        if (!_gz.containsKey(wk)) pending.add(wk);
        for (final f in streetFallbackFor(want, _has)) {
          items.add((streetTileKey(f), f, want));
          if (f.z != tz) fallback = true;
        }
      }
    }
    if (items.isEmpty) return null;
    return _Want(key, e, tz, lngW, latN, deg, items, pending, fallback);
  }

  List<StreetTile> _labelTiles() {
    final out = <String, StreetTile>{};
    for (final t in plan.tiles) {
      for (final f in streetFallbackFor(t, _has)) {
        final k = streetTileKey(f);
        final d = _tiles[k];
        if (d != null) out[k] = d;
      }
    }
    return out.values.toList();
  }

  bool paint(Canvas canvas, Size size, GeoView view,
      {required bool light, required double dpr}) {
    final s = size.isEmpty ? 0.0 : view.scale(size);
    final e = s > 0 ? streetBucketExp(s) : 0;
    final tz = !_enabled || !plan.draw || s <= 0
        ? null
        : (plan.bucketExp == e ? plan.tz : streetTileZoomOfBucket(e));
    if (tz == null || _gz.isEmpty) {
      _drewLast = false;
      _setAttribution(false);
      return false;
    }
    final clock = Stopwatch()..start();
    final bs = streetBucketScaleOf(e);
    final deg = kStreetBlockPx / bs;
    final w = view.cx - size.width / 2 / s, east = view.cx + size.width / 2 / s;
    final n = view.cy + size.height / 2 / s, south = view.cy - size.height / 2 / s;
    final bx0 = ((w + 180) / deg).floor(), bx1 = ((east + 180) / deg).floor();
    final by0 = ((90 - n) / deg).floor(), by1 = ((90 - south) / deg).floor();
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

    var absent = false;
    for (var by = by0; by <= by1 && !absent; by++) {
      for (var bx = bx0; bx <= bx1; bx++) {
        if (!_blocks.containsKey('${light ? 'l' : 'd'}|$e|$tz|$bx|$by')) {
          absent = true;
          break;
        }
      }
    }
    var standIn = 0;
    void drawAlt(int alt) {
      for (final b in _blocks.values) {
        if (b.light != light || b.e != alt) continue;
        if (b.lngW >= east || b.lngW + b.deg <= w || b.latN <= south || b.latN - b.deg >= n) {
          continue;
        }
        blit(b);
        standIn++;
      }
    }

    for (final alt in absent ? [e - 2, e + 2, e - 1, e + 1] : [e - 1, e + 1]) {
      drawAlt(alt);
    }
    for (var alt = e - 3; absent && standIn == 0 && alt >= e - 12; alt--) {
      drawAlt(alt);
    }
    _want.clear();
    final used = <String>{};
    for (var by = by0; by <= by1; by++) {
      for (var bx = bx0; bx <= bx1; bx++) {
        final key = '${light ? 'l' : 'd'}|$e|$tz|$bx|$by';
        final b = _blocks.remove(key);
        if (b != null) {
          _blocks[key] = b;
          used.add(key);
          blit(b);
          continue;
        }
        final want = _blockWant(key, e, tz, -180 + bx * deg, 90 - by * deg, deg);
        if (want != null) _want.add(want);
      }
    }
    _trimBlocks(used);
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

  Rect _clipOf(StreetTileId t, double lngW, double latN, double k) {
    final side = (1 << t.z).toDouble();
    final tw = t.x / side * 360 - 180, te = (t.x + 1) / side * 360 - 180;
    final tn = streetTileLatOf(t.y.toDouble(), t.z), ts = streetTileLatOf(t.y + 1.0, t.z);
    return Rect.fromLTRB((tw - lngW) * k, (latN - tn) * k, (te - lngW) * k, (latN - ts) * k);
  }

  void _rasterize(bool light, double dpr, int maxBlocks, int budgetUs) {
    final clock = Stopwatch()..start();
    var made = 0;
    final jobs = <String, StreetTileJob>{};
    for (final q in [..._want]) {
      if (made >= maxBlocks || clock.elapsedMicroseconds > budgetUs) break;
      if (_blocks.containsKey(q.key)) continue;
      final w = _blockWant(q.key, q.e, q.tz, q.lngW, q.latN, q.deg);
      if (w == null) continue;
      final bs = streetBucketScaleOf(w.e);
      final ready = <(StreetTile, Rect?)>[];
      var waiting = false;
      for (final (k, f, want) in w.items) {
        if (_tiles.containsKey(k)) {
          final t = _tiles.remove(k);
          _tiles[k] = t;
          if (t != null) ready.add((t, f.z < want.z ? _clipOf(want, w.lngW, w.latN, bs) : null));
          continue;
        }
        final gz = _gz[k];
        if (gz == null) continue;
        waiting = true;
        if (!_decoding.contains(k)) jobs[k] = StreetTileJob(z: f.z, x: f.x, y: f.y, gz: gz);
      }
      if (waiting) continue;
      final t0 = clock.elapsedMicroseconds;
      final img = _rasterBlock(ready, w.lngW, w.latN, bs, dpr, light, streetBucketZvOf(w.e));
      stats
        ..rasterUs += clock.elapsedMicroseconds - t0
        ..rasterBlocks += 1;
      final bytes = img.width * img.height * 4;
      _blocks[w.key] = _Block(img, w.e, light, bytes, w);
      _blockBytes += bytes;
      made++;
    }
    if (jobs.isNotEmpty) _decode(jobs);
    if (made > 0) notifyListeners();
  }

  void _decode(Map<String, StreetTileJob> jobs) {
    _decoding.addAll(jobs.keys);
    final gen = _gen;
    final b = _build;
    _decoder(jobs.values.toList()).then((out) {
      _decoding.removeAll(jobs.keys);
      if (_disposed || _halted || gen != _gen || b != _build) return;
      var i = 0;
      for (final e in jobs.entries) {
        final t = out[i++];
        if (t == null && e.value.gz.isNotEmpty && b != null) {
          final g = _gz.remove(e.key);
          if (g != null) _gzBytes -= g.length;
          _negative(b, e.key, kStreet.malformedRetryMs);
          continue;
        }
        if (_gz.containsKey(e.key)) _tiles[e.key] = t;
      }
      while (_tiles.length > kStreet.memDecodedTiles) {
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

  ui.Image _rasterBlock(List<(StreetTile, Rect?)> tiles, double lngW, double latN, double k,
      double dpr, bool light, double bucketZv) {
    final px = (kStreetBlockPx * dpr).round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.clipRect(Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()));
    c.scale(dpr);
    paintStreetTiles(c, tiles, lngW, latN, k, light, bucketZv, _path);
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
    final bz = streetBucketZvOf(streetBucketExp(s));
    final fs = zv >= 16 ? 12.0 : 11.0;
    final waterFill = (light ? StreetPalette.light : StreetPalette.dark).waterLabel;
    final w = view.cx - size.width / 2 / s, e = view.cx + size.width / 2 / s;
    final n = view.cy + size.height / 2 / s, so = view.cy - size.height / 2 / s;
    final cands = <(int, double, StreetLabelCandidate, double, TextPainter, bool)>[];
    for (final t in _labelTiles()) {
      final x0 = w - t.lngW, x1 = e - t.lngW, y0 = t.latN - n, y1 = t.latN - so;
      for (final src in t.labels) {
        if (!streetLabelAllowed(src.cls, bz) || !streetRoadDrawn(src.mz, bz)) continue;
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
    final idx = placeLineLabels([for (final c in cands) c.$3], blocked,
        maxLabels: streetMaxLabels(bz));
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
    StreetHalt.remove(_halt);
    _stop();
    for (final b in _blocks.values) {
      b.image.dispose();
    }
    _blocks.clear();
    attribution.dispose();
    super.dispose();
  }
}

void paintStreetTiles(Canvas c, List<(StreetTile, Rect?)> tiles, double lngW, double latN,
    double k, bool light, double zv, ui.Path Function(StreetGroup g) pathOf) {
  final pal = light ? StreetPalette.light : StreetPalette.dark;
  final river = light ? const Color(0xB35A96BE) : const Color(0x8C4678A0);
  final unit = 1 / k;
  void each(void Function(StreetGroup g) fn) {
    for (final (t, clip) in tiles) {
      c.save();
      if (clip != null) c.clipRect(clip);
      c.translate((t.lngW - lngW) * k, (latN - t.latN) * k);
      c.scale(k);
      for (final g in t.groups) {
        if (streetRoadDrawn(g.mz, zv)) fn(g);
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
  final low = zv < 12.99;
  void roads(int st, bool casing, double alpha) {
    for (final cls in casing ? _cased : _fillOrder) {
      final base = casing ? pal.casing : (low ? pal.lowRoad[cls] : null) ?? pal.road[cls]!;
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

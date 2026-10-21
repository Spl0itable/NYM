import 'dart:math' as math;

const double kNiMaxHorizontalDeg = 15;
const double kNiMaxVerticalDeg = 25;
const double kNiMaxDistanceM = 4;
const double kNiCloseDistanceM = 0.5;
const int kNiHoldMs = 400;
const int kNiStaleMs = 1500;
const double _eps = 1e-6;

double _deg(double rad) => rad * 180 / math.pi;
double _rad(double deg) => deg * math.pi / 180;

double niHorizontalDeg(double x, double z) => _deg(math.atan2(x, -z));

double niVerticalDeg(double x, double y, double z) =>
    _deg(math.atan2(y, math.sqrt(x * x + z * z)));

class NiSample {
  const NiSample({this.distance, this.x, this.y, this.z});

  factory NiSample.fromAngles(double h, double v, double distance) {
    final hr = _rad(h);
    final vr = _rad(v);
    return NiSample(
      distance: distance,
      x: math.cos(vr) * math.sin(hr),
      y: math.sin(vr),
      z: -math.cos(vr) * math.cos(hr),
    );
  }

  final double? distance;
  final double? x;
  final double? y;
  final double? z;

  bool get hasDirection => x != null && y != null && z != null;

  double? get horizontal => hasDirection ? niHorizontalDeg(x!, z!) : null;

  bool get inCone {
    final d = distance;
    if (d == null || !hasDirection || d > kNiMaxDistanceM + _eps) return false;
    return niHorizontalDeg(x!, z!).abs() <= kNiMaxHorizontalDeg + _eps &&
        niVerticalDeg(x!, y!, z!).abs() <= kNiMaxVerticalDeg + _eps;
  }

  bool get isClose {
    final d = distance;
    return d != null && d <= kNiCloseDistanceM + _eps;
  }
}

class _Track {
  _Track(this.sample, this.at, this.inSince);
  NiSample sample;
  int at;
  int? inSince;
}

class NearbyPointer {
  final Map<String, _Track> _tracks = {};

  void update(String peer, NiSample sample, int now) {
    final t = _tracks[peer];
    final inCone = sample.inCone;
    if (t == null) {
      _tracks[peer] = _Track(sample, now, inCone ? now : null);
      return;
    }
    t.inSince = inCone ? (t.inSince ?? now) : null;
    t.sample = sample;
    t.at = now;
  }

  void remove(String peer) => _tracks.remove(peer);

  void clear() => _tracks.clear();

  String? pick(int now) {
    String? aimed;
    double? bestH;
    String? close;
    double? bestD;
    for (final e in _tracks.entries) {
      final t = e.value;
      if (now - t.at > kNiStaleMs) continue;
      final since = t.inSince;
      if (since != null && now - since >= kNiHoldMs) {
        final h = t.sample.horizontal!.abs();
        if (bestH == null || h < bestH) {
          bestH = h;
          aimed = e.key;
        }
      }
      if (t.sample.isClose) {
        final d = t.sample.distance!;
        if (bestD == null || d < bestD) {
          bestD = d;
          close = e.key;
        }
      }
    }
    return aimed ?? close;
  }
}

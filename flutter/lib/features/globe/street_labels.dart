import 'dart:math' as math;

class LineLabelParams {
  const LineLabelParams();
  final double endPad = 8;
  final double maxTurnDeg = 20;
  final double edgePad = 4;
  final double repeatPx = 256;
  final int maxLabels = 40;
}

const LineLabelParams kLineLabel = LineLabelParams();

class StreetBox {
  const StreetBox(this.x0, this.y0, this.x1, this.y1);
  final double x0;
  final double y0;
  final double x1;
  final double y1;
}

class StreetLineLabel {
  const StreetLineLabel(this.x, this.y, this.angle, this.boxes);
  final double x;
  final double y;
  final double angle;
  final List<StreetBox> boxes;
}

class StreetLabelCandidate {
  const StreetLabelCandidate(
      {required this.name, required this.x, required this.y, required this.boxes});
  final String name;
  final double x;
  final double y;
  final List<StreetBox> boxes;
}

double _turn(double a, double b) {
  var d = b - a;
  while (d > math.pi) {
    d -= 2 * math.pi;
  }
  while (d < -math.pi) {
    d += 2 * math.pi;
  }
  return d.abs();
}

List<StreetBox> streetLabelBoxes(
    double cx, double cy, double angle, double textW, double textH) {
  final k = math.max(1, (textW / textH).ceil());
  final c = math.cos(angle), s = math.sin(angle), half = textH / 2;
  return [
    for (var q = 0; q < k; q++)
      () {
        final t = k == 1 ? 0.0 : -textW / 2 + half + q * (textW - textH) / (k - 1);
        final bx = cx + c * t, by = cy + s * t;
        return StreetBox(bx - half, by - half, bx + half, by + half);
      }()
  ];
}

StreetLineLabel? lineLabel(
    List<double> pts, double textW, double textH, double width, double height) {
  final lim = kLineLabel.maxTurnDeg * math.pi / 180;
  final need = textW + 2 * kLineLabel.endPad, pad = kLineLabel.edgePad;
  final n = pts.length ~/ 2;
  double? bestLen;
  var bcx = 0.0, bcy = 0.0, bdx = 0.0, bdy = 0.0;
  var i = 0;
  while (i < n - 1) {
    final dx0 = pts[2 * i + 2] - pts[2 * i], dy0 = pts[2 * i + 3] - pts[2 * i + 1];
    if (dx0 == 0 && dy0 == 0) {
      i++;
      continue;
    }
    final a0 = math.atan2(dy0, dx0);
    var j = i + 1;
    while (j < n - 1) {
      final dx = pts[2 * j + 2] - pts[2 * j], dy = pts[2 * j + 3] - pts[2 * j + 1];
      if (dx == 0 && dy == 0) {
        j++;
        continue;
      }
      if (_turn(a0, math.atan2(dy, dx)) > lim) break;
      j++;
    }
    final x0 = pts[2 * i], y0 = pts[2 * i + 1], x1 = pts[2 * j], y1 = pts[2 * j + 1];
    final len = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    if (len >= need &&
        cx >= pad &&
        cx <= width - pad &&
        cy >= pad &&
        cy <= height - pad &&
        (bestLen == null || len > bestLen)) {
      bestLen = len;
      bcx = cx;
      bcy = cy;
      bdx = x1 - x0;
      bdy = y1 - y0;
    }
    i = j;
  }
  if (bestLen == null) return null;
  var a = math.atan2(bdy, bdx);
  if (a > math.pi / 2) {
    a -= math.pi;
  } else if (a <= -math.pi / 2) {
    a += math.pi;
  }
  return StreetLineLabel(bcx, bcy, a, streetLabelBoxes(bcx, bcy, a, textW, textH));
}

List<int> placeLineLabels(
    List<StreetLabelCandidate?> cands, List<StreetBox> blocked,
    {double pad = 2, int? maxLabels}) {
  final cap = maxLabels ?? kLineLabel.maxLabels;
  final placed = [...blocked];
  final out = <int>[];
  final seen = <StreetLabelCandidate>[];
  bool hit(StreetBox b) => placed.any((o) =>
      b.x0 - pad < o.x1 && o.x0 < b.x1 + pad && b.y0 - pad < o.y1 && o.y0 < b.y1 + pad);
  for (var i = 0; i < cands.length && out.length < cap; i++) {
    final c = cands[i];
    if (c == null) continue;
    if (seen.any((s) =>
        s.name == c.name &&
        math.sqrt((s.x - c.x) * (s.x - c.x) + (s.y - c.y) * (s.y - c.y)) <
            kLineLabel.repeatPx)) {
      continue;
    }
    if (c.boxes.any(hit)) continue;
    placed.addAll(c.boxes);
    seen.add(c);
    out.add(i);
  }
  return out;
}

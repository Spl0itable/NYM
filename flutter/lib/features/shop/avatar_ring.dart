import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'avatar_ring_specs.dart';
import 'avatar_ring_visual.dart';

export 'avatar_ring_visual.dart';

enum AvatarRingClass { tiny, row, header, profile }

AvatarRingClass avatarRingClassFor(double size, {bool featured = false}) {
  if (size <= kAvatarRingTinyMax) return AvatarRingClass.tiny;
  if (size > kAvatarRingRowMax) return AvatarRingClass.profile;
  return featured ? AvatarRingClass.header : AvatarRingClass.row;
}

({double width, double gap}) avatarRingBand(double size,
    {AvatarRingClass? ringClass}) {
  switch (ringClass ?? avatarRingClassFor(size)) {
    case AvatarRingClass.tiny:
      return (
        width: size < kAvatarRingTinySmallBelow
            ? kAvatarRingTinyWidthSmall
            : kAvatarRingTinyWidth,
        gap: 0,
      );
    case AvatarRingClass.row:
    case AvatarRingClass.header:
      return (width: size * kAvatarRingRowWidth, gap: size * kAvatarRingRowGap);
    case AvatarRingClass.profile:
      return (
        width: size * kAvatarRingProfileWidth,
        gap: size * kAvatarRingProfileGap,
      );
  }
}

double avatarRingInset(double size, {AvatarRingClass? ringClass}) {
  final b = avatarRingBand(size, ringClass: ringClass);
  return b.width + b.gap;
}

bool avatarRingMotionVisible(
  AvatarRingVisual visual, {
  required bool isLight,
  required bool highContrast,
}) {
  final motion = visual.motion;
  if (motion == null) return false;
  final pal = visual.palette(isLight: isLight, highContrast: highContrast);
  return motion.layer.stops.any((s) => (pal[s.key]?.a ?? 0) > 0);
}

bool avatarRingMoves(
  AvatarRingVisual visual, {
  required bool featured,
  bool isLight = false,
  bool highContrast = false,
}) =>
    featured &&
    visual.legendary &&
    avatarRingMotionVisible(visual, isLight: isLight, highContrast: highContrast);

final Map<String, Path> _paths = {};

Path avatarRingPath(String d) => _paths[d] ??= _parsePath(d);

Path _parsePath(String d) {
  final path = Path();
  final tokens = RegExp(r'[MLCQZ]|-?\d*\.?\d+(?:e-?\d+)?').allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  double next() => double.parse(tokens[i++]);
  var cmd = 'M';
  while (i < tokens.length) {
    final t = tokens[i];
    if (RegExp(r'^[MLCQZ]$').hasMatch(t)) {
      cmd = t;
      i++;
      if (cmd == 'Z') {
        path.close();
        continue;
      }
    }
    switch (cmd) {
      case 'M':
        path.moveTo(next(), next());
        cmd = 'L';
      case 'L':
        path.lineTo(next(), next());
      case 'C':
        path.cubicTo(next(), next(), next(), next(), next(), next());
      case 'Q':
        path.quadraticBezierTo(next(), next(), next(), next());
      default:
        i++;
    }
  }
  return path;
}

double _rad(double deg) => deg * math.pi / 180;

Shader _sweep(AvatarRingSweep s, Map<String, Color> pal, Offset c, double turn) {
  return SweepGradient(
    colors: [for (final st in s.stops) pal[st.key] ?? const Color(0x00000000)],
    stops: [for (final st in s.stops) st.at],
    transform: GradientRotation(_rad(s.from) - math.pi / 2 + turn * 2 * math.pi),
  ).createShader(Rect.fromCircle(center: c, radius: 1));
}

Paint? _paint(AvatarRingPaint? p, Map<String, Color> pal) {
  if (p == null) return null;
  switch (p.kind) {
    case AvatarRingPaintKind.solid:
      return Paint()..color = pal[p.key] ?? const Color(0x00000000);
    case AvatarRingPaintKind.linear:
      return Paint()
        ..shader = ui.Gradient.linear(
          Offset(p.coords[0], p.coords[1]),
          Offset(p.coords[2], p.coords[3]),
          [for (final s in p.stops) pal[s.key] ?? const Color(0x00000000)],
          [for (final s in p.stops) s.at],
        );
    case AvatarRingPaintKind.radial:
      return Paint()
        ..shader = ui.Gradient.radial(
          Offset(p.coords[0], p.coords[1]),
          p.coords[2],
          [for (final s in p.stops) pal[s.key] ?? const Color(0x00000000)],
          [for (final s in p.stops) s.at],
        );
  }
}

void _drawOps(Canvas canvas, List<AvatarRingOp> ops, Map<String, Color> pal) {
  for (final o in ops) {
    if (o.kind == AvatarRingOpKind.clip) {
      canvas.save();
      canvas.clipPath(Path.from(avatarRingPath(o.d))..fillType = PathFillType.evenOdd);
      _drawOps(canvas, o.ops, pal);
      canvas.restore();
      continue;
    }
    final fill = _paint(o.fill, pal);
    final stroke = _paint(o.stroke, pal);
    for (final p in [fill, stroke]) {
      if (p == null) continue;
      p.isAntiAlias = true;
      if (o.blur > 0) p.maskFilter = MaskFilter.blur(BlurStyle.normal, o.blur);
    }
    if (stroke != null) {
      stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = o.sw
        ..strokeCap = o.cap ?? StrokeCap.butt
        ..strokeJoin = StrokeJoin.round;
    }
    switch (o.kind) {
      case AvatarRingOpKind.circle:
        final c = Offset(o.cx, o.cy);
        if (fill != null) canvas.drawCircle(c, o.r, fill);
        if (stroke != null) canvas.drawCircle(c, o.r, stroke);
      case AvatarRingOpKind.path:
        final path = o.evenOdd
            ? (Path.from(avatarRingPath(o.d))..fillType = PathFillType.evenOdd)
            : avatarRingPath(o.d);
        if (fill != null) canvas.drawPath(path, fill);
        if (stroke != null) canvas.drawPath(path, stroke);
      case AvatarRingOpKind.arc:
        if (stroke != null) {
          canvas.drawArc(
            Rect.fromCircle(center: const Offset(50, 50), radius: o.r),
            _rad(o.a0) - math.pi / 2,
            _rad(o.a1 - o.a0),
            false,
            stroke,
          );
        }
      case AvatarRingOpKind.clip:
        break;
    }
  }
}

class AvatarRingPainter extends CustomPainter {
  const AvatarRingPainter({
    required this.visual,
    required this.ringClass,
    required this.isLight,
    required this.highContrast,
    required this.fill,
  });

  final AvatarRingVisual visual;
  final AvatarRingClass ringClass;
  final bool isLight;
  final bool highContrast;
  final Color fill;

  static final Map<String, AvatarRingPainter> _cache = {};

  static AvatarRingPainter cached({
    required AvatarRingVisual visual,
    required AvatarRingClass ringClass,
    required bool isLight,
    required bool highContrast,
    required Color fill,
  }) {
    final key = '${visual.id}|${ringClass.name}|$isLight|$highContrast|${fill.toARGB32()}';
    if (_cache.length > 256 && !_cache.containsKey(key)) _cache.clear();
    return _cache[key] ??= AvatarRingPainter(
      visual: visual,
      ringClass: ringClass,
      isLight: isLight,
      highContrast: highContrast,
      fill: fill,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final pal = visual.palette(isLight: isLight, highContrast: highContrast);
    final band = avatarRingBand(s, ringClass: ringClass);
    final c = Offset(s / 2, s / 2);
    final rOut = s / 2;
    final rIn = rOut - band.width;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: rOut)));
    final body = ringClass == AvatarRingClass.tiny ? visual.tiny : visual.body;
    if (body != null) {
      canvas.drawCircle(
        c,
        rOut - band.width / 2,
        Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeWidth = band.width + 0.5
          ..shader = _sweep(body, pal, c, 0),
      );
    }
    canvas.drawCircle(c, rIn, Paint()..color = fill);
    final tint = visual.tint;
    if (tint != null && !highContrast && ringClass != AvatarRingClass.tiny) {
      canvas.drawCircle(c, rIn, Paint()..color = pal[tint] ?? const Color(0x00000000));
    }
    if (ringClass != AvatarRingClass.tiny) {
      final ops = ringClass == AvatarRingClass.profile ? visual.artProfile : visual.artRow;
      if (ops.isNotEmpty) {
        canvas.scale(s / 100);
        _drawOps(canvas, ops, pal);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AvatarRingPainter old) =>
      old.visual != visual ||
      old.ringClass != ringClass ||
      old.isLight != isLight ||
      old.highContrast != highContrast ||
      old.fill != fill;
}

class AvatarRingIconPainter extends CustomPainter {
  const AvatarRingIconPainter({
    required this.visual,
    required this.isLight,
    required this.highContrast,
  });

  final AvatarRingVisual visual;
  final bool isLight;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final pal = visual.palette(isLight: isLight, highContrast: highContrast);
    final w = s * 0.16;
    final c = Offset(s / 2, s / 2);
    canvas.drawCircle(
      c,
      s / 2 - w / 2,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = _sweep(visual.tiny, pal, c, 0),
    );
  }

  @override
  bool shouldRepaint(AvatarRingIconPainter old) =>
      old.visual != visual ||
      old.isLight != isLight ||
      old.highContrast != highContrast;
}

class AvatarRingFeaturePainter extends CustomPainter {
  AvatarRingFeaturePainter({
    required this.visual,
    required this.isLight,
    required this.highContrast,
    this.turn,
  }) : super(repaint: turn);

  final AvatarRingVisual visual;
  final bool isLight;
  final bool highContrast;
  final Animation<double>? turn;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final pal = visual.palette(isLight: isLight, highContrast: highContrast);
    final motion = visual.motion;
    final t = turn;
    if (motion != null && t != null) {
      final band = avatarRingBand(s);
      final c = Offset(s / 2, s / 2);
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: s / 2)));
      canvas.drawCircle(
        c,
        s / 2 - band.width / 2,
        Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeWidth = band.width + 0.5
          ..shader = _sweep(motion.layer, pal, c, t.value),
      );
      canvas.restore();
    }
    final hero = visual.hero;
    if (hero != null && hero.isNotEmpty) {
      canvas.save();
      canvas.scale(s / 100);
      _drawOps(canvas, hero, pal);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(AvatarRingFeaturePainter old) =>
      old.visual != visual ||
      old.isLight != isLight ||
      old.highContrast != highContrast ||
      old.turn != turn;
}

class AvatarRingFeature extends StatefulWidget {
  const AvatarRingFeature({
    super.key,
    required this.visual,
    required this.size,
    required this.isLight,
    required this.highContrast,
  });

  final AvatarRingVisual visual;
  final double size;
  final bool isLight;
  final bool highContrast;

  @override
  State<AvatarRingFeature> createState() => _AvatarRingFeatureState();
}

class _AvatarRingFeatureState extends State<AvatarRingFeature>
    with TickerProviderStateMixin {
  AnimationController? _turn;

  bool _wantsMotion(BuildContext context) =>
      avatarRingMoves(
        widget.visual,
        featured: true,
        isLight: widget.isLight,
        highContrast: widget.highContrast,
      ) &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;

  void _sync() {
    final want = _wantsMotion(context);
    if (want && _turn == null) {
      _turn = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: widget.visual.motion!.periodMs),
      )..repeat();
    } else if (!want && _turn != null) {
      _turn!.dispose();
      _turn = null;
    } else if (want && _turn!.duration!.inMilliseconds != widget.visual.motion!.periodMs) {
      _turn!.duration = Duration(milliseconds: widget.visual.motion!.periodMs);
      _turn!.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AvatarRingFeature old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _turn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: AvatarRingFeaturePainter(
          visual: widget.visual,
          isLight: widget.isLight,
          highContrast: widget.highContrast,
          turn: _turn,
        ),
      ),
    );
  }
}

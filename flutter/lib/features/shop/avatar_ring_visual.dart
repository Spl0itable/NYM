import 'dart:ui';

import 'avatar_ring_specs.dart';

class AvatarRingStop {
  const AvatarRingStop(this.key, this.at);

  final String key;
  final double at;
}

class AvatarRingSweep {
  const AvatarRingSweep(this.from, this.stops);

  final double from;
  final List<AvatarRingStop> stops;
}

enum AvatarRingPaintKind { solid, linear, radial }

class AvatarRingPaint {
  const AvatarRingPaint.solid(this.key)
      : kind = AvatarRingPaintKind.solid,
        coords = const [],
        stops = const [];

  const AvatarRingPaint.linear(this.coords, this.stops)
      : kind = AvatarRingPaintKind.linear,
        key = '';

  const AvatarRingPaint.radial(this.coords, this.stops)
      : kind = AvatarRingPaintKind.radial,
        key = '';

  final AvatarRingPaintKind kind;
  final String key;
  final List<double> coords;
  final List<AvatarRingStop> stops;
}

enum AvatarRingOpKind { circle, path, arc, clip }

class AvatarRingOp {
  const AvatarRingOp.circle({
    required this.cx,
    required this.cy,
    required this.r,
    this.fill,
    this.stroke,
    this.sw = 0,
    this.blur = 0,
    this.cap,
  })  : kind = AvatarRingOpKind.circle,
        d = '',
        a0 = 0,
        a1 = 0,
        evenOdd = false,
        ops = const [];

  const AvatarRingOp.path({
    required this.d,
    this.fill,
    this.stroke,
    this.sw = 0,
    this.evenOdd = false,
    this.blur = 0,
    this.cap,
  })  : kind = AvatarRingOpKind.path,
        cx = 0,
        cy = 0,
        r = 0,
        a0 = 0,
        a1 = 0,
        ops = const [];

  const AvatarRingOp.arc({
    required this.r,
    required this.a0,
    required this.a1,
    required this.stroke,
    required this.sw,
    this.blur = 0,
    this.cap,
  })  : kind = AvatarRingOpKind.arc,
        d = '',
        cx = 50,
        cy = 50,
        fill = null,
        evenOdd = false,
        ops = const [];

  const AvatarRingOp.clip({required this.d, required this.ops})
      : kind = AvatarRingOpKind.clip,
        cx = 0,
        cy = 0,
        r = 0,
        a0 = 0,
        a1 = 0,
        fill = null,
        stroke = null,
        sw = 0,
        blur = 0,
        evenOdd = true,
        cap = null;

  final AvatarRingOpKind kind;
  final String d;
  final double cx;
  final double cy;
  final double r;
  final double a0;
  final double a1;
  final AvatarRingPaint? fill;
  final AvatarRingPaint? stroke;
  final double sw;
  final double blur;
  final bool evenOdd;
  final StrokeCap? cap;
  final List<AvatarRingOp> ops;
}

class AvatarRingMotion {
  const AvatarRingMotion({
    required this.kind,
    required this.periodMs,
    required this.layer,
  });

  final String kind;
  final int periodMs;
  final AvatarRingSweep layer;
}

class AvatarRingVisual {
  const AvatarRingVisual({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.tier,
    this.inspiredBy,
    required this.ornament,
    required this.dark,
    required this.light,
    required this.hcDark,
    required this.hcLight,
    required this.edge,
    required this.tiny,
    this.body,
    this.tint,
    required this.artRow,
    required this.artProfile,
    this.hero,
    this.motion,
  });

  final String id;
  final String name;
  final String description;
  final int price;
  final String tier;
  final String? inspiredBy;
  final String ornament;
  final Map<String, Color> dark;
  final Map<String, Color> light;
  final Map<String, Color> hcDark;
  final Map<String, Color> hcLight;
  final List<String> edge;
  final AvatarRingSweep tiny;
  final AvatarRingSweep? body;
  final String? tint;
  final List<AvatarRingOp> artRow;
  final List<AvatarRingOp> artProfile;
  final List<AvatarRingOp>? hero;
  final AvatarRingMotion? motion;

  bool get legendary => tier == 'legendary';

  Map<String, Color> palette({required bool isLight, required bool highContrast}) {
    if (highContrast) return isLight ? hcLight : hcDark;
    return isLight ? light : dark;
  }

  static final Map<String, AvatarRingVisual> _byId = {
    for (final r in kAvatarRings) r.id: r,
  };

  static AvatarRingVisual? byId(String? id) => id == null ? null : _byId[id];
}

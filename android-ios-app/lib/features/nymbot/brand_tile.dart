import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'brand_marks.dart';

class SvgPath {
  const SvgPath._();

  static ui.Path parse(String d) {
    final path = ui.Path();
    final scan = _Scanner(d);
    var current = Offset.zero;
    var start = Offset.zero;
    Offset? lastCubic;
    var command = '';
    while (!scan.done) {
      final next = scan.command();
      if (next != null) {
        command = next;
      } else if (command.isEmpty) {
        break;
      } else if (command == 'M') {
        command = 'L';
      } else if (command == 'm') {
        command = 'l';
      }
      final relative = command == command.toLowerCase();
      final base = relative ? current : Offset.zero;
      switch (command.toUpperCase()) {
        case 'M':
          current = Offset(scan.number(), scan.number()) + base;
          start = current;
          path.moveTo(current.dx, current.dy);
          lastCubic = null;
          break;
        case 'L':
          current = Offset(scan.number(), scan.number()) + base;
          path.lineTo(current.dx, current.dy);
          lastCubic = null;
          break;
        case 'H':
          current = Offset(scan.number() + base.dx, current.dy);
          path.lineTo(current.dx, current.dy);
          lastCubic = null;
          break;
        case 'V':
          current = Offset(current.dx, scan.number() + base.dy);
          path.lineTo(current.dx, current.dy);
          lastCubic = null;
          break;
        case 'C':
          final c1 = Offset(scan.number(), scan.number()) + base;
          final c2 = Offset(scan.number(), scan.number()) + base;
          current = Offset(scan.number(), scan.number()) + base;
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, current.dx, current.dy);
          lastCubic = c2;
          break;
        case 'S':
          final c1 = lastCubic == null ? current : current * 2 - lastCubic;
          final c2 = Offset(scan.number(), scan.number()) + base;
          current = Offset(scan.number(), scan.number()) + base;
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, current.dx, current.dy);
          lastCubic = c2;
          break;
        case 'Q':
          final c1 = Offset(scan.number(), scan.number()) + base;
          current = Offset(scan.number(), scan.number()) + base;
          path.quadraticBezierTo(c1.dx, c1.dy, current.dx, current.dy);
          lastCubic = null;
          break;
        case 'A':
          final rx = scan.number();
          final ry = scan.number();
          final rotation = scan.number();
          final largeArc = scan.flag();
          final sweep = scan.flag();
          final end = Offset(scan.number(), scan.number()) + base;
          if (rx == 0 || ry == 0 || end == current) {
            path.lineTo(end.dx, end.dy);
          } else {
            path.arcToPoint(
              end,
              radius: Radius.elliptical(rx, ry),
              rotation: rotation,
              largeArc: largeArc,
              clockwise: sweep,
            );
          }
          current = end;
          lastCubic = null;
          break;
        case 'Z':
          path.close();
          current = start;
          lastCubic = null;
          break;
        default:
          return path;
      }
    }
    return path;
  }
}

class _Scanner {
  _Scanner(this.source);

  final String source;
  int at = 0;

  void _skip() {
    while (at < source.length) {
      final c = source.codeUnitAt(at);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x2c) {
        at++;
      } else {
        break;
      }
    }
  }

  bool get done {
    _skip();
    return at >= source.length;
  }

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  String? command() {
    _skip();
    if (at >= source.length) return null;
    final c = source.codeUnitAt(at);
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) {
      at++;
      return source[at - 1];
    }
    return null;
  }

  double number() {
    _skip();
    final from = at;
    if (at < source.length &&
        (source.codeUnitAt(at) == 0x2b || source.codeUnitAt(at) == 0x2d)) {
      at++;
    }
    while (at < source.length && _digit(source.codeUnitAt(at))) {
      at++;
    }
    if (at < source.length && source.codeUnitAt(at) == 0x2e) {
      at++;
      while (at < source.length && _digit(source.codeUnitAt(at))) {
        at++;
      }
    }
    if (at < source.length &&
        (source.codeUnitAt(at) == 0x65 || source.codeUnitAt(at) == 0x45)) {
      final save = at;
      at++;
      if (at < source.length &&
          (source.codeUnitAt(at) == 0x2b || source.codeUnitAt(at) == 0x2d)) {
        at++;
      }
      if (at < source.length && _digit(source.codeUnitAt(at))) {
        while (at < source.length && _digit(source.codeUnitAt(at))) {
          at++;
        }
      } else {
        at = save;
      }
    }
    if (from == at) return 0;
    return double.parse(source.substring(from, at));
  }

  bool flag() {
    _skip();
    if (at >= source.length) return false;
    final c = source.codeUnitAt(at);
    at++;
    return c == 0x31;
  }
}

class BrandMarks {
  const BrandMarks._();

  static Map<String, BrandMark> get marks => BrandMarkTable.marks;

  static String canonical(String slug) => BrandMarkTable.canonical(slug);

  static BrandMark? of(String slug) => BrandMarkTable.of(slug);

  static int tintFor(String slug) => BrandMarkTable.tintFor(slug);

  static String initials(String slug) => BrandMarkTable.initials(slug);

  static List<ui.Path> geometry(String slug) {
    final mark = of(slug);
    if (mark == null) return const [];
    return mark.paths.map(SvgPath.parse).toList();
  }
}

class BrandTile extends StatelessWidget {
  const BrandTile({super.key, required this.slug, this.size = 22});

  final String slug;
  final double size;

  static const double _pad = 4.4;

  @override
  Widget build(BuildContext context) {
    final mark = BrandMarks.of(slug);
    if (mark == null) {
      final text = BrandMarks.initials(slug);
      return SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(BrandMarks.tintFor(slug)),
            borderRadius: BorderRadius.circular(size * 0.25),
          ),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: text.length > 1 ? size * 0.38 : size * 0.46,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BrandPainter(
          fill: Color(mark.color),
          box: mark.box,
          geometry: BrandMarks.geometry(slug),
        ),
      ),
    );
  }
}

class _BrandPainter extends CustomPainter {
  _BrandPainter({required this.fill, required this.box, required this.geometry});

  final Color fill;
  final Rect box;
  final List<ui.Path> geometry;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(6 * unit),
      ),
      Paint()..color = fill,
    );
    final inset = 24 - BrandTile._pad * 2;
    final scale = inset / (box.width > box.height ? box.width : box.height);
    final dx = BrandTile._pad + (inset - box.width * scale) / 2 - box.left * scale;
    final dy = BrandTile._pad + (inset - box.height * scale) / 2 - box.top * scale;
    canvas.save();
    canvas.scale(unit);
    canvas.translate(dx, dy);
    canvas.scale(scale);
    final ink = Paint()..color = Colors.white;
    for (final path in geometry) {
      canvas.drawPath(path, ink);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BrandPainter old) =>
      old.fill != fill || old.geometry != geometry;
}

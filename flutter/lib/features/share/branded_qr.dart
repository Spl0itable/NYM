import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'share_links.dart' show kShareCodeMaxBytes;

const String kBrandedQrMarkAsset = 'assets/images/NYM-circle.png';
const int kBrandedQrQuietZone = 4;
const int kBrandedQrExportModulePx = 10;
const double kBrandedQrMinSide = 240;
const double kBrandedQrPlateFraction = 0.22;
const double kBrandedQrMarkFraction = 0.82;

class BrandedQrMatrix {
  BrandedQrMatrix._(this.version, this.moduleCount, this._image);
  final int version;
  final int moduleCount;
  final QrImage _image;

  bool isDark(int row, int col) => _image.isDark(row, col);
}

BrandedQrMatrix? brandedQrMatrix(String data) {
  if (data.isEmpty || data.codeUnits.any((c) => c > 0x7E || c < 0x20)) {
    return null;
  }
  if (utf8.encode(data).length > kShareCodeMaxBytes) return null;
  final result = QrValidator.validate(
    data: data,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.H,
  );
  final code = result.qrCode;
  if (result.status != QrValidationStatus.valid || code == null) return null;
  final image = QrImage(code);
  return BrandedQrMatrix._(code.typeNumber, image.moduleCount, image);
}

int brandedQrPlateDiameter(int moduleCount, double modulePx) =>
    (kBrandedQrPlateFraction * moduleCount * modulePx).floor();

double brandedQrMarkSide(int plate) => plate * kBrandedQrMarkFraction;

Future<ui.Image>? _markFuture;

Future<ui.Image> loadBrandedQrMark() {
  return _markFuture ??= () async {
    final data = await rootBundle.load(kBrandedQrMarkAsset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(),
        targetWidth: 512);
    final frame = await codec.getNextFrame();
    return frame.image;
  }();
}

void paintBrandedQr(
    Canvas canvas, double side, BrandedQrMatrix m, ui.Image? mark) {
  final total = m.moduleCount + 2 * kBrandedQrQuietZone;
  final px = side / total;
  canvas.drawRect(
      Rect.fromLTWH(0, 0, side, side), Paint()..color = const Color(0xFFFFFFFF));
  final dark = Paint()
    ..color = const Color(0xFF000000)
    ..isAntiAlias = false;
  for (var r = 0; r < m.moduleCount; r++) {
    var c = 0;
    while (c < m.moduleCount) {
      if (!m.isDark(r, c)) {
        c++;
        continue;
      }
      final start = c;
      while (c < m.moduleCount && m.isDark(r, c)) {
        c++;
      }
      canvas.drawRect(
        Rect.fromLTRB(
          (start + kBrandedQrQuietZone) * px,
          (r + kBrandedQrQuietZone) * px,
          (c + kBrandedQrQuietZone) * px,
          (r + 1 + kBrandedQrQuietZone) * px,
        ),
        dark,
      );
    }
  }
  final plate = brandedQrPlateDiameter(m.moduleCount, px);
  final center = Offset(side / 2, side / 2);
  canvas.drawCircle(
      center, plate / 2, Paint()..color = const Color(0xFFFFFFFF));
  if (mark != null) {
    final s = brandedQrMarkSide(plate);
    canvas.drawImageRect(
      mark,
      Rect.fromLTWH(0, 0, mark.width.toDouble(), mark.height.toDouble()),
      Rect.fromCenter(center: center, width: s, height: s),
      Paint()..filterQuality = FilterQuality.high,
    );
  }
}

Future<ui.Image> brandedQrImage(BrandedQrMatrix m,
    {int modulePx = kBrandedQrExportModulePx, ui.Image? mark}) {
  final side = (m.moduleCount + 2 * kBrandedQrQuietZone) * modulePx;
  final recorder = ui.PictureRecorder();
  paintBrandedQr(Canvas(recorder), side.toDouble(), m, mark);
  final picture = recorder.endRecording();
  return picture.toImage(side, side).whenComplete(picture.dispose);
}

Future<Uint8List?> brandedQrPng(String data, {ui.Image? mark}) async {
  final m = brandedQrMatrix(data);
  if (m == null) return null;
  final image = await brandedQrImage(m, mark: mark ?? await loadBrandedQrMark());
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class BrandedQrPainter extends CustomPainter {
  BrandedQrPainter(this.matrix, this.mark);
  final BrandedQrMatrix matrix;
  final ui.Image? mark;

  @override
  void paint(Canvas canvas, Size size) =>
      paintBrandedQr(canvas, size.shortestSide, matrix, mark);

  @override
  bool shouldRepaint(BrandedQrPainter old) =>
      old.matrix != matrix || old.mark != mark;
}

class BrandedQr extends StatefulWidget {
  const BrandedQr({
    super.key,
    required this.data,
    required this.semanticLabel,
    this.size = kBrandedQrMinSide,
  });

  final String data;
  final String semanticLabel;
  final double size;

  @override
  State<BrandedQr> createState() => _BrandedQrState();
}

class _BrandedQrState extends State<BrandedQr> {
  BrandedQrMatrix? _matrix;
  ui.Image? _mark;

  @override
  void initState() {
    super.initState();
    _matrix = brandedQrMatrix(widget.data);
    unawaited(loadBrandedQrMark().then((img) {
      if (mounted) setState(() => _mark = img);
    }, onError: (_) {}));
  }

  @override
  void didUpdateWidget(BrandedQr old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _matrix = brandedQrMatrix(widget.data);
  }

  @override
  Widget build(BuildContext context) {
    final side =
        widget.size < kBrandedQrMinSide ? kBrandedQrMinSide : widget.size;
    final m = _matrix;
    return Semantics(
      label: widget.semanticLabel,
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: side,
        child: m == null
            ? const SizedBox.shrink()
            : RepaintBoundary(
                child: CustomPaint(
                  size: Size.square(side),
                  painter: BrandedQrPainter(m, _mark),
                ),
              ),
      ),
    );
  }
}

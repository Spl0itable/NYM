import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'media_notes.dart';

class CompressedPhoto {
  const CompressedPhoto(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;
}

bool compressibleImageMime(String mime) {
  final m = baseMime(mime);
  return m == 'image/jpeg' || m == 'image/png' || m == 'image/webp';
}

CompressedPhoto? compressPhotoSync(
    ({Uint8List bytes, int maxDimension, double quality}) args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  final dims = scaledDimensions(oriented.width, oriented.height, args.maxDimension);
  final resized = dims.width == oriented.width && dims.height == oriented.height
      ? oriented
      : img.copyResize(oriented,
          width: dims.width,
          height: dims.height,
          interpolation: img.Interpolation.average);
  final flat = resized.hasAlpha
      ? img.compositeImage(
          img.Image(width: resized.width, height: resized.height)
            ..clear(img.ColorRgb8(255, 255, 255)),
          resized)
      : resized;
  final out = img.encodeJpg(flat, quality: (args.quality * 100).round());
  return CompressedPhoto(out, flat.width, flat.height);
}

Future<Uint8List?> compressPhoto(Uint8List bytes, String mime,
    {int maxDimension = MediaNoteLimits.photoMaxDimension,
    double quality = MediaNoteLimits.photoQuality}) async {
  if (!compressibleImageMime(mime)) return null;
  try {
    final r = await compute(compressPhotoSync,
        (bytes: bytes, maxDimension: maxDimension, quality: quality));
    if (r == null || r.bytes.length >= bytes.length) return null;
    return r.bytes;
  } catch (_) {
    return null;
  }
}

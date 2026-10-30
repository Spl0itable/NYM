import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

@immutable
class CoverResizeKey {
  const CoverResizeKey(this.inner, this.width, this.height);

  final Object inner;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is CoverResizeKey &&
      other.inner == inner &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(inner, width, height);
}

@immutable
class CoverResizeImage extends ImageProvider<CoverResizeKey> {
  const CoverResizeImage(this.imageProvider,
      {required this.width, required this.height});

  final ImageProvider<Object> imageProvider;
  final int width;
  final int height;

  static ui.TargetImageSize coverSize(
      int intrinsicWidth, int intrinsicHeight, int width, int height) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return const ui.TargetImageSize();
    }
    final scale = math.min(
        1.0, math.max(width / intrinsicWidth, height / intrinsicHeight));
    return ui.TargetImageSize(
      width: math.max(1, (intrinsicWidth * scale).ceil()),
      height: math.max(1, (intrinsicHeight * scale).ceil()),
    );
  }

  @override
  Future<CoverResizeKey> obtainKey(ImageConfiguration configuration) =>
      imageProvider
          .obtainKey(configuration)
          .then((key) => CoverResizeKey(key, width, height));

  @override
  ImageStreamCompleter loadImage(
      CoverResizeKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> cover(ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) =>
        decode(buffer,
            getTargetSize: (w, h) => coverSize(w, h, width, height));
    return imageProvider.loadImage(key.inner, cover);
  }

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImage &&
      other.imageProvider == imageProvider &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(imageProvider, width, height);
}

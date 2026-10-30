import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class BlurredPhoto extends SingleChildRenderObjectWidget {
  const BlurredPhoto({super.key, required this.sigma, super.child});

  final double sigma;

  @override
  RenderBlurredPhoto createRenderObject(BuildContext context) =>
      RenderBlurredPhoto(sigma);

  @override
  void updateRenderObject(
      BuildContext context, RenderBlurredPhoto renderObject) {
    renderObject.sigma = sigma;
  }
}

class RenderBlurredPhoto extends RenderProxyBox {
  RenderBlurredPhoto(this._sigma);

  static const double _downscale = 4;
  static const double _minSide = 48;

  double _sigma;
  double get sigma => _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    _drop();
    markNeedsPaint();
  }

  ui.Image? _blurred;
  ui.Image? _source;
  Size? _blurredSize;
  final LayerHandle<ImageFilterLayer> _live = LayerHandle<ImageFilterLayer>();

  @override
  bool get alwaysNeedsCompositing => child != null;

  RenderImage? _imageBox() {
    RenderImage? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderImage) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    final c = child;
    if (c != null) visit(c);
    return found;
  }

  void _drop() {
    _blurred?.dispose();
    _blurred = null;
    _source?.dispose();
    _source = null;
    _blurredSize = null;
  }

  ui.Image _render(ui.Image image, RenderImage box) {
    final scale = math.min(_downscale,
        math.max(1.0, math.min(size.width, size.height) / _minSide));
    final w = math.max(1, (size.width / scale).ceil());
    final h = math.max(1, (size.height / scale).ceil());
    final bounds = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
              sigmaX: sigma * w / size.width, sigmaY: sigma * h / size.height));
    paintImage(
      canvas: canvas,
      rect: bounds,
      image: image,
      fit: box.fit,
      alignment: box.alignment.resolve(box.textDirection),
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    final out = picture.toImageSync(w, h);
    picture.dispose();
    return out;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final box = _imageBox();
    final image = box?.image;
    if (box == null || image == null || size.isEmpty) {
      _drop();
      final layer = _live.layer ??= ImageFilterLayer();
      layer
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)
        ..offset = offset;
      context.pushLayer(layer, super.paint, Offset.zero);
      return;
    }
    _live.layer = null;
    var blurred = _blurred;
    if (blurred == null ||
        _blurredSize != size ||
        !(_source?.isCloneOf(image) ?? false)) {
      _drop();
      _source = image.clone();
      _blurredSize = size;
      blurred = _blurred = _render(image, box);
    }
    context.canvas.drawImageRect(
      blurred,
      Rect.fromLTWH(0, 0, blurred.width.toDouble(), blurred.height.toDouble()),
      offset & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    _UnshownContext(ContainerLayer(), offset & size)
        .paintAndDrop(child!, offset);
  }

  @override
  void dispose() {
    _drop();
    _live.layer = null;
    super.dispose();
  }
}

class _UnshownContext extends PaintingContext {
  _UnshownContext(this._root, Rect bounds) : super(_root, bounds);

  final ContainerLayer _root;

  void paintAndDrop(RenderObject child, Offset offset) {
    paintChild(child, offset);
    stopRecordingIfNeeded();
    _root
      ..removeAllChildren()
      ..dispose();
  }
}

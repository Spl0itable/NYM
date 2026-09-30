// Animated image that detaches its stream listener while not visible, so offscreen GIFs stop decoding frames.

import 'package:flutter/widgets.dart';
import 'package:visibility_detector/visibility_detector.dart';

class PausableAnimatedImage extends StatefulWidget {
  const PausableAnimatedImage({
    super.key,
    required this.image,
    required this.visibilityKey,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorBuilder,
  });

  /// The already resize-capped provider.
  final ImageProvider image;

  /// Stable identity for the visibility region, e.g. `ValueKey(url)`.
  final Key visibilityKey;

  final double? width;
  final double? height;
  final BoxFit fit;

  final Widget? placeholder;

  final WidgetBuilder? errorBuilder;

  @override
  State<PausableAnimatedImage> createState() => _PausableAnimatedImageState();
}

class _PausableAnimatedImageState extends State<PausableAnimatedImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageStreamCompleterHandle? _keepAlive;
  ImageInfo? _frame;
  bool _listening = false;
  bool _visible = true;
  bool _error = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PausableAnimatedImage old) {
    super.didUpdateWidget(old);
    if (widget.image != old.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(
      context,
      size: (widget.width != null && widget.height != null)
          ? Size(widget.width!, widget.height!)
          : null,
    ));
    if (stream.key == _stream?.key) return;
    _detach();
    _stream = stream;
    _error = false;
    _attachIfVisible();
  }

  void _attachIfVisible() {
    final stream = _stream;
    if (!_visible || _listening || stream == null) return;
    _listener ??= ImageStreamListener(_onFrame, onError: _onError);
    try {
      stream.addListener(_listener!);
    } on Object {
      // The completer was disposed while detached and addListener would throw, so resolve afresh (bytes are cached).
      _stream = null;
      _keepAlive?.dispose();
      _keepAlive = null;
      _resolve();
      return;
    }
    _listening = true;
    // Listening keeps the completer alive; drop the pause pin.
    _keepAlive?.dispose();
    _keepAlive = null;
  }

  /// Stops frames while pinning the completer; never before the first frame, or the image never loads.
  void _pause() {
    final stream = _stream;
    final completer = stream?.completer;
    if (!_listening || stream == null || completer == null || _frame == null) {
      return;
    }
    _keepAlive = completer.keepAlive();
    stream.removeListener(_listener!);
    _listening = false;
  }

  void _onFrame(ImageInfo info, bool syncCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _frame?.dispose();
      _frame = info;
    });
    // Deferred pause: went offscreen before the first frame arrived.
    if (!_visible) _pause();
  }

  void _onError(Object error, StackTrace? stackTrace) {
    if (mounted) setState(() => _error = true);
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction > 0;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _attachIfVisible();
    } else {
      _pause();
    }
  }

  void _detach() {
    if (_listening && _listener != null) _stream?.removeListener(_listener!);
    _listening = false;
    _keepAlive?.dispose();
    _keepAlive = null;
  }

  @override
  void dispose() {
    _detach();
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_error) {
      body = widget.errorBuilder?.call(context) ??
          SizedBox(width: widget.width, height: widget.height);
    } else if (_frame == null) {
      body = widget.placeholder ??
          SizedBox(width: widget.width, height: widget.height);
    } else {
      body = RawImage(
        image: _frame!.image,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        scale: _frame!.scale,
      );
    }
    return VisibilityDetector(
      key: widget.visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: body,
    );
  }
}

// Visibility-gated playback for ANIMATED images (GIF / animated WebP).
//
// Flutter's `Image` keeps an animated codec ticking for as long as the widget
// is mounted — and a chat list keeps rows mounted well beyond the visible
// screen (the viewport cache extent). Several animated GIFs therefore decode
// + upload frames continuously even when none of them are on screen, a
// permanent CPU/GPU load that reads as the whole conversation being laggy.
//
// [PausableAnimatedImage] renders frames from the raw [ImageStream] and
// simply DETACHES its listener while the widget is not visible: with no
// listeners the framework's `MultiFrameImageStreamCompleter` stops driving
// the codec, freezing the image on its last decoded frame at zero cost. A
// kept-alive handle pins the completer (and its decoded state) while paused,
// so resuming never refetches or restarts the decode. Visibility comes from
// `visibility_detector`, which reports through the render tree — scrolled
// out, behind another route, or inside an offstage subtree all count as
// hidden.

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

  /// The (already resize-capped) provider for the animated image.
  final ImageProvider image;

  /// Stable identity for the visibility region (e.g. `ValueKey(url)`).
  final Key visibilityKey;

  final double? width;
  final double? height;
  final BoxFit fit;

  /// Shown until the first frame decodes.
  final Widget? placeholder;

  /// Shown when the stream reports an error.
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
      // The completer was disposed while we were detached (the framework
      // drops a completer with no listeners and no keep-alive handles, and
      // addListener on a disposed one THROWS — in release builds too).
      // Start over with a fresh resolve; the bytes are still in the disk /
      // memory caches, so this is cheap.
      _stream = null;
      _keepAlive?.dispose();
      _keepAlive = null;
      _resolve();
      return;
    }
    _listening = true;
    // Listening keeps the completer alive on its own; drop the pause pin.
    _keepAlive?.dispose();
    _keepAlive = null;
  }

  /// Stops frame delivery (and thereby the codec) without losing the decoded
  /// state: the keep-alive handle pins the completer so a later
  /// [_attachIfVisible] resumes instantly from where it froze.
  ///
  /// Never pauses BEFORE the first frame: rows materialize inside the list's
  /// cache extent, where the visibility detector reports `visibleFraction ==
  /// 0` immediately — often while the network fetch is still in flight and
  /// `stream.completer` is null. Detaching at that point leaves nothing
  /// pinned, so the framework disposes the completer as soon as its own
  /// bookkeeping listener drops, and the image can never load ("GIFs stopped
  /// loading"). Once the first frame lands, [_onFrame] re-checks visibility
  /// and freezes offscreen images on that frame.
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
    // Deferred pause (see [_pause]): the widget went offscreen before its
    // first frame arrived — freeze on this frame now that there is a
    // completer to pin and a sized frame to keep the layout alive.
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

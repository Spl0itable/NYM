// Inline video that initializes on first tap and falls back to opening the URL externally if every source fails.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../i18n/i18n.dart';
import '../../../core/utils/safe_url.dart';
import 'media_source.dart';
import 'message_content.dart' show proxiedMedia;

const double _kVideoRadius = 12;

/// Tap-to-play video tile; [maxSize] caps both dimensions, [bordered] adds the single-video border.
class VideoMessage extends StatefulWidget {
  const VideoMessage({
    super.key,
    required this.url,
    this.fallbackUrls = const [],
    this.maxSize = 300,
    this.borderRadius,
    this.bordered = true,
  });

  final String url;

  /// NIP-92 imeta mirror URLs tried in order when the primary source fails.
  final List<String> fallbackUrls;

  final double maxSize;
  final BorderRadius? borderRadius;
  final bool bordered;

  @override
  State<VideoMessage> createState() => _VideoMessageState();
}

class _VideoMessageState extends State<VideoMessage> {
  VideoPlayerController? _controller;

  /// Desktop hover only; [MouseRegion] never fires on touch.
  bool _hovered = false;

  bool _initializing = false;

  /// Primary and every mirror failed; show tap-to-open.
  bool _failed = false;

  /// The source that initialized, or the last one tried.
  String? _activeUrl;

  @override
  void dispose() {
    _controller?.removeListener(_onValue);
    _controller?.dispose();
    super.dispose();
  }

  void _onValue() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_initializing || _controller != null) return;
    setState(() => _initializing = true);
    final opened = await openMediaSource(
      [widget.url, ...widget.fallbackUrls],
      _tryOpen,
    );
    if (opened != null || !mounted) return;
    setState(() {
      _initializing = false;
      _failed = true;
    });
  }

  Future<bool> _tryOpen(String candidate) async {
    final uri = Uri.tryParse(candidate);
    if (!mounted) return true;
    if (uri == null) return false;
    _activeUrl = candidate;
    final controller = VideoPlayerController.networkUrl(uri);
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      return false;
    }
    if (!mounted) {
      await controller.dispose();
      return true;
    }
    controller.addListener(_onValue);
    setState(() {
      _controller = controller;
      _initializing = false;
    });
    await controller.play();
    return true;
  }

  Future<void> _openExternally() async {
    await launchSafeUrl(_activeUrl ?? proxiedMedia(widget.url));
  }

  void _togglePlayback() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = widget.borderRadius ??
        const BorderRadius.all(Radius.circular(_kVideoRadius));

    Widget body;
    if (_failed) {
      body = _fallbackTile(c);
    } else if (_controller != null && _controller!.value.isInitialized) {
      body = _playerTile(c);
    } else {
      body = _posterTile(c);
    }

    Widget result;
    if (!widget.bordered) {
      // Gallery cells have no border and are clipped by the grid.
      result = ClipRRect(
        borderRadius: radius,
        child: AnimatedScale(
          scale: _hovered ? 1.02 : 1.0,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          child: body,
        ),
      );
    } else {
      result = AnimatedScale(
        scale: _hovered ? 1.02 : 1.0,
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.15)
                  : c.glassBorder,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: c.isLight ? 0.1 : 0.4),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(borderRadius: radius, child: body),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: result,
    );
  }

  /// Constraints shared by every state.
  BoxConstraints get _constraints => BoxConstraints(
        maxWidth: widget.maxSize,
        maxHeight: widget.maxSize,
        minHeight: 80,
      );

  Widget _posterTile(NymColors c) {
    return GestureDetector(
      onTap: _start,
      child: Container(
        constraints: _constraints,
        // 16:9 poster footprint until the real aspect ratio is known.
        width: widget.maxSize,
        height: widget.maxSize * 9 / 16,
        color: c.bgTertiary,
        alignment: Alignment.center,
        child: _initializing
            ? SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(c.text),
                ),
              )
            : Icon(Icons.play_circle_fill, size: 48, color: c.text),
      ),
    );
  }

  /// Live player with play/pause overlay, scrubber and fullscreen button.
  Widget _playerTile(NymColors c) {
    final controller = _controller!;
    final value = controller.value;
    return ConstrainedBox(
      constraints: _constraints,
      child: AspectRatio(
        aspectRatio: value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlayback,
                child: AnimatedOpacity(
                  opacity: value.isPlaying ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    alignment: Alignment.center,
                    child: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      size: 48,
                      color: c.text,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: VideoProgressColors(
                  playedColor: c.primary,
                  bufferedColor: Colors.white.withValues(alpha: 0.3),
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ),
            // Fades in on hover but stays visible on touch devices; still hit-tests while hidden, like CSS opacity 0.
            Positioned(
              top: 8,
              right: 8,
              child: AnimatedOpacity(
                opacity: _touchPlatform(context) || _hovered ? 1.0 : 0.0,
                duration: NymMotion.transition,
                curve: NymMotion.curve,
                child: _ExpandButton(onTap: _openFullscreen),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Init-failed fallback that opens the URL externally.
  Widget _fallbackTile(NymColors c) {
    return GestureDetector(
      onTap: _openExternally,
      child: Container(
        constraints: _constraints,
        width: widget.maxSize,
        height: widget.maxSize * 9 / 16,
        color: c.bgTertiary,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new, size: 32, color: c.text),
            const SizedBox(height: 6),
            Text(
              tr('Open video'),
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// On touch-primary platforms the expand button stays visible.
  bool _touchPlatform(BuildContext context) {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  /// Full-screen dialog reusing the same controller so playback continues.
  void _openFullscreen() {
    final controller = _controller;
    if (controller == null) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.9),
        pageBuilder: (_, __, ___) => _FullscreenVideo(controller: controller),
      ),
    );
  }
}

class _ExpandButton extends StatelessWidget {
  const _ExpandButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius:
                const BorderRadius.all(Radius.circular(_kVideoRadius)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: const Icon(Icons.fullscreen, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// Full-screen overlay reusing [controller]; backdrop or close dismisses, video tap toggles play.
class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  void _onValue() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValue);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final value = controller.value;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          children: [
            Center(
              child: GestureDetector(
                onTap: () => setState(() {
                  if (value.isPlaying) {
                    controller.pause();
                  } else {
                    controller.play();
                  }
                }),
                child: AspectRatio(
                  aspectRatio: value.isInitialized ? value.aspectRatio : 16 / 9,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Colors.white30,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

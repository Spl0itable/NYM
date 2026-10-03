import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import '../messages/media_fallbacks.dart';
import '../messages/format/media_source.dart';
import 'media_note_files.dart';
import 'media_notes.dart';
import 'voice_note_player.dart' show activeMediaNoteProvider;

const double kRoundNoteSize = 200;

class RoundVideoNote extends ConsumerStatefulWidget {
  const RoundVideoNote({
    super.key,
    required this.note,
    this.localPath,
    this.size = kRoundNoteSize,
    this.autoStart = true,
  });

  final MediaNote note;
  final String? localPath;
  final double size;
  final bool autoStart;

  @override
  ConsumerState<RoundVideoNote> createState() => _RoundVideoNoteState();
}

class _RoundVideoNoteState extends ConsumerState<RoundVideoNote> {
  final Object _token = Object();
  VideoPlayerController? _controller;
  bool _starting = false;
  bool _failed = false;
  bool _sound = false;
  bool _visible = false;
  String? _tempPath;

  @override
  void dispose() {
    _controller?.removeListener(_onValue);
    _controller?.dispose();
    MediaNoteFiles.deleteQuietly(_tempPath);
    super.dispose();
  }

  void _onValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (_sound &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        !v.isPlaying &&
        v.position >= v.duration - const Duration(milliseconds: 150)) {
      _backToLoop();
      return;
    }
    setState(() {});
  }

  Future<void> _ensure() async {
    if (_controller != null || _starting || _failed) return;
    _starting = true;
    try {
      final local = widget.localPath;
      if (local != null) {
        final bytes = await MediaNoteFiles.readLocal(local);
        _tempPath = await MediaNoteFiles.writeTemp(bytes, widget.note.mime);
        final c = VideoPlayerController.file(File(_tempPath!));
        await c.initialize();
        _adopt(c);
        return;
      }
      final opened = await openMediaSource([
        widget.note.url,
        ...ref.read(mediaFallbacksProvider).fallbacksFor(widget.note.url),
      ], (url) async {
        final uri = Uri.tryParse(url);
        if (uri == null) return false;
        final c = VideoPlayerController.networkUrl(uri);
        try {
          await c.initialize();
        } catch (_) {
          await c.dispose();
          return false;
        }
        if (!mounted) {
          await c.dispose();
          return true;
        }
        _adopt(c);
        return true;
      });
      if (opened == null && mounted) setState(() => _failed = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _starting = false;
    }
  }

  void _adopt(VideoPlayerController c) {
    if (!mounted) {
      c.dispose();
      return;
    }
    c.addListener(_onValue);
    c.setVolume(0);
    c.setLooping(true);
    setState(() => _controller = c);
    if (_visible) c.play();
  }

  void _onVisibility(VisibilityInfo info) {
    final visible = info.visibleFraction > 0.4;
    if (visible == _visible) return;
    _visible = visible;
    final c = _controller;
    if (visible) {
      if (c == null) {
        if (widget.autoStart) _ensure();
      } else if (!c.value.isPlaying) {
        c.play();
      }
    } else if (c != null && c.value.isPlaying) {
      c.pause();
      if (_sound) _backToLoop(play: false);
    }
  }

  Future<void> _backToLoop({bool play = true}) async {
    final c = _controller;
    if (c == null) return;
    _sound = false;
    await c.setVolume(0);
    await c.setLooping(true);
    if (play) await c.play();
    if (mounted) setState(() {});
  }

  Future<void> _tap() async {
    await _ensure();
    final c = _controller;
    if (c == null) return;
    if (_sound) {
      await _backToLoop();
      return;
    }
    ref.read(activeMediaNoteProvider.notifier).state = _token;
    _sound = true;
    await c.setLooping(false);
    await c.seekTo(Duration.zero);
    await c.setVolume(1);
    await c.play();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.nym;
    ref.listen<Object?>(activeMediaNoteProvider, (_, next) {
      if (next != _token && _sound) _backToLoop();
    });
    final c = _controller;
    final ready = c != null && c.value.isInitialized;
    double progress = 0;
    if (ready && _sound && c.value.duration > Duration.zero) {
      progress = (c.value.position.inMilliseconds / c.value.duration.inMilliseconds)
          .clamp(0.0, 1.0);
    }
    final clock = widget.note.duration == null ? '' : formatClock(widget.note.duration!);
    final s = widget.size;
    Widget video;
    if (ready) {
      final vs = c.value.size;
      video = FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: vs.width <= 0 ? s : vs.width,
          height: vs.height <= 0 ? s : vs.height,
          child: VideoPlayer(c),
        ),
      );
    } else {
      video = Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: _failed
            ? Icon(Icons.videocam_off, color: colors.textDim)
            : (_starting
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: colors.primary))
                : Icon(Icons.play_arrow, color: colors.text, size: 36)),
      );
    }
    return VisibilityDetector(
      key: ValueKey('round-${widget.note.url}-${widget.localPath}'),
      onVisibilityChanged: _onVisibility,
      child: Semantics(
        button: true,
        label: tr('Play video note with sound'),
        child: GestureDetector(
          key: const ValueKey('roundNote'),
          onTap: _tap,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            width: s,
            height: s,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipOval(child: video),
                if (_sound)
                  CustomPaint(
                      painter: _RingPainter(progress, colors.primary)),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_sound ? '\u{1F50A}' : '\u{1F507}'} $clock',
                        key: const ValueKey('roundBadge'),
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(2.5, 2.5, size.width - 5, size.height - 5);
    canvas.drawArc(rect, -math.pi / 2, progress * 2 * math.pi, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

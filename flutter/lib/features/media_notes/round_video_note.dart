import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import '../layout/chat_cover.dart';
import '../messages/media_fallbacks.dart';
import '../messages/format/media_source.dart';
import '../messages/format/playback_keeper.dart';
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
    this.playbackScope,
  });

  final MediaNote note;
  final String? localPath;
  final double size;
  final bool autoStart;
  final String? playbackScope;

  @override
  ConsumerState<RoundVideoNote> createState() => _RoundVideoNoteState();
}

class _RoundVideoNoteState extends ConsumerState<RoundVideoNote> {
  final Key _visibilityKey = UniqueKey();
  SharedPlayback? _session;
  bool _starting = false;
  bool _failed = false;
  bool _visible = false;
  bool _covered = false;
  bool _ticking = true;
  String? _tempPath;

  bool get _shown => _visible && !_covered && _ticking;

  VideoPlayerController? get _controller => _session?.controller;

  bool get _sound => _session?.sound ?? false;

  String? _keyOf(RoundVideoNote w) {
    final scope = w.playbackScope;
    if (scope == null) return null;
    return PlaybackKeeper.keyFor(scope, w.localPath ?? w.note.url);
  }

  @override
  void initState() {
    super.initState();
    _bind(_keyOf(widget));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = ChatCoverScope.of(context);
    final ticking = TickerMode.valuesOf(context).enabled;
    if (covered == _covered && ticking == _ticking) return;
    _covered = covered;
    _ticking = ticking;
    _session
      ?..markCovered(this, covered)
      ..markTicking(this, ticking);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _covered == covered && _ticking == ticking) {
        _followCover();
      }
    });
  }

  void _followCover() {
    if (!_covered && _ticking) {
      _playIfShown();
      return;
    }
    final s = _session;
    if (s != null &&
        !s.sound &&
        !s.shown &&
        s.controller.value.isPlaying) {
      s.controller.pause();
    }
  }

  @override
  void didUpdateWidget(RoundVideoNote oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = _keyOf(oldWidget);
    final key = _keyOf(widget);
    if (old == key &&
        oldWidget.note.url == widget.note.url &&
        oldWidget.localPath == widget.localPath) {
      return;
    }
    _unbind(old);
    _failed = false;
    _bind(key);
    if (_session == null && _shown && widget.autoStart) _ensure();
  }

  @override
  void dispose() {
    _unbind(_keyOf(widget));
    VisibilityDetectorController.instance.forget(_visibilityKey);
    MediaNoteFiles.deleteQuietly(_tempPath);
    super.dispose();
  }

  void _bind(String? key) {
    PlaybackKeeper.watch(key, _onStarted);
    final s = PlaybackKeeper.join(key, this);
    if (s != null) _attach(s);
  }

  void _unbind(String? key) {
    PlaybackKeeper.unwatch(key, _onStarted);
    final s = _session;
    _session = null;
    if (s == null) return;
    s.controller.removeListener(_onValue);
    PlaybackKeeper.leave(s, this);
  }

  void _attach(SharedPlayback s) {
    if (identical(_session, s)) return;
    s.controller.addListener(_onValue);
    _session = s;
    _failed = false;
    s.markVisible(this, _visible);
    s.markCovered(this, _covered);
    s.markTicking(this, _ticking);
  }

  void _onStarted() {
    if (!mounted || _session != null) return;
    final s = PlaybackKeeper.join(_keyOf(widget), this);
    if (s == null) return;
    setState(() => _attach(s));
    if (_shown && !s.controller.value.isPlaying) s.controller.play();
  }

  void _onValue() {
    final s = _session;
    if (s == null || !mounted) return;
    final v = s.controller.value;
    if (s.sound &&
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
    if (_session != null || _starting || _failed) return;
    _starting = true;
    try {
      final local = widget.localPath;
      if (local != null) {
        final bytes = await MediaNoteFiles.readLocal(local);
        final temp = await MediaNoteFiles.writeTemp(bytes, widget.note.mime);
        _tempPath = temp;
        final c = VideoPlayerController.file(File(temp));
        try {
          await c.initialize();
        } catch (_) {
          await c.dispose();
          rethrow;
        }
        _tempPath = null;
        _adopt(c, onRelease: () => MediaNoteFiles.deleteQuietly(temp));
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

  void _adopt(VideoPlayerController c, {VoidCallback? onRelease}) {
    final key = _keyOf(widget);
    if (!mounted && key == null) {
      c.dispose();
      onRelease?.call();
      return;
    }
    c.setVolume(0);
    c.setLooping(true);
    final s = PlaybackKeeper.start(key, this, c, onRelease: onRelease);
    if (!mounted) {
      PlaybackKeeper.leave(s, this);
      return;
    }
    setState(() => _attach(s));
    if (_shown && !s.controller.value.isPlaying) s.controller.play();
  }

  void _onVisibility(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction > 0.4;
    if (visible && _visible) return;
    _visible = visible;
    final s = _session;
    s?.markVisible(this, visible);
    if (visible) {
      _playIfShown();
    } else if (!_covered &&
        s != null &&
        !s.seen &&
        s.controller.value.isPlaying) {
      s.controller.pause();
      if (s.sound) _backToLoop(play: false);
    }
  }

  void _playIfShown() {
    if (!_shown) return;
    final s = _session;
    if (s == null) {
      if (widget.autoStart) _ensure();
    } else if (!s.controller.value.isPlaying) {
      s.controller.play();
    }
  }

  Future<void> _backToLoop({bool play = true}) async {
    final s = _session;
    if (s == null) return;
    final c = s.controller;
    s.sound = false;
    await c.setVolume(0);
    await c.setLooping(true);
    if ((_covered || !_ticking) && !s.shown) {
      if (c.value.isPlaying) await c.pause();
    } else if (play) {
      await c.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _tap() async {
    await _ensure();
    final s = _session;
    if (s == null || !mounted) return;
    final c = s.controller;
    if (s.sound) {
      await _backToLoop();
      return;
    }
    ref.read(activeMediaNoteProvider.notifier).state = s;
    s.sound = true;
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
      final s = _session;
      if (s != null && !identical(next, s) && s.sound) _backToLoop();
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
      key: _visibilityKey,
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

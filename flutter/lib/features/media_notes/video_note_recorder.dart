import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'media_notes.dart';

class RecordedVideoNote {
  const RecordedVideoNote({
    required this.path,
    required this.duration,
    required this.mime,
    required this.once,
  });

  final String path;
  final double duration;
  final String mime;
  final bool once;
}

enum VideoNotePhase { idle, recording, review }

String videoNoteHint(VideoNotePhase phase, int maxSeconds) {
  switch (phase) {
    case VideoNotePhase.review:
      return tr('Send it, or delete and try again.');
    case VideoNotePhase.recording:
      return tr('Tap to stop. Video notes are up to {max}.',
          {'max': formatClock(maxSeconds)});
    case VideoNotePhase.idle:
      return tr('Tap the button to start recording.');
  }
}

String mimeForRecordedVideo(String path) =>
    path.toLowerCase().endsWith('.mov') ? 'video/quicktime' : 'video/mp4';

Future<RecordedVideoNote?> showVideoNoteRecorder(
  BuildContext context, {
  required bool onceAllowed,
  int maxSeconds = MediaNoteLimits.roundMaxSeconds,
  void Function(bool recording)? onRecording,
}) {
  return showDialog<RecordedVideoNote>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.8),
    builder: (_) => VideoNoteRecorder(
        onceAllowed: onceAllowed,
        maxSeconds: maxSeconds,
        onRecording: onRecording),
  );
}

class VideoNoteRecorder extends StatefulWidget {
  const VideoNoteRecorder({
    super.key,
    required this.onceAllowed,
    required this.maxSeconds,
    this.onRecording,
  });

  final bool onceAllowed;
  final int maxSeconds;
  final void Function(bool recording)? onRecording;

  @override
  State<VideoNoteRecorder> createState() => _VideoNoteRecorderState();
}

class _VideoNoteRecorderState extends State<VideoNoteRecorder> {
  CameraController? _camera;
  VideoPlayerController? _review;
  VideoNotePhase _phase = VideoNotePhase.idle;
  DateTime? _startedAt;
  double _duration = 0;
  Timer? _tick;
  String? _path;
  String? _error;
  bool _once = false;

  double get _elapsed => _phase == VideoNotePhase.recording && _startedAt != null
      ? DateTime.now().difference(_startedAt!).inMilliseconds / 1000
      : _duration;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('none');
      final front = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => cams.first);
      final ctl = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: true,
        fps: 30,
        videoBitrate: MediaNoteLimits.roundVideoBitrate,
        audioBitrate: MediaNoteLimits.roundAudioBitrate,
      );
      await ctl.initialize();
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() => _camera = ctl);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is CameraException && e.code.contains('Denied')
          ? tr("Camera or microphone access was denied, so video notes can't be recorded.")
          : tr(MediaNoteReasons.roundNoCamera));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_phase == VideoNotePhase.recording) widget.onRecording?.call(false);
    _camera?.dispose();
    _review?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final cam = _camera;
    if (cam == null) return;
    if (_phase == VideoNotePhase.recording) {
      await _stop();
      return;
    }
    if (_phase != VideoNotePhase.idle) return;
    try {
      await cam.startVideoRecording();
    } catch (_) {
      setState(() => _error = tr(MediaNoteReasons.roundNoCamera));
      return;
    }
    _startedAt = DateTime.now();
    setState(() => _phase = VideoNotePhase.recording);
    widget.onRecording?.call(true);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_elapsed >= widget.maxSeconds) _stop();
      if (mounted) setState(() {});
    });
  }

  Future<void> _stop() async {
    final cam = _camera;
    if (cam == null || _phase != VideoNotePhase.recording) return;
    _tick?.cancel();
    _duration = _elapsed.clamp(0, widget.maxSeconds).toDouble();
    setState(() => _phase = VideoNotePhase.review);
    widget.onRecording?.call(false);
    try {
      final file = await cam.stopVideoRecording();
      _path = file.path;
      final r = VideoPlayerController.file(File(file.path));
      await r.initialize();
      await r.setVolume(0);
      await r.setLooping(true);
      await r.play();
      if (!mounted) {
        await r.dispose();
        return;
      }
      setState(() => _review = r);
    } catch (_) {
      if (mounted) setState(() => _error = tr(MediaNoteReasons.roundNoCamera));
    }
  }

  void _send() {
    final p = _path;
    if (p == null) return;
    Navigator.of(context).pop(RecordedVideoNote(
      path: p,
      duration: _duration,
      mime: mimeForRecordedVideo(p),
      once: _once,
    ));
  }

  void _close() {
    final p = _path;
    if (p != null) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = (MediaQuery.of(context).size.width * 0.7).clamp(160.0, 260.0);
    final cam = _camera;
    Widget preview;
    if (_review != null && _review!.value.isInitialized) {
      final vs = _review!.value.size;
      preview = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: vs.width, height: vs.height, child: VideoPlayer(_review!)),
      );
    } else if (cam != null && cam.value.isInitialized) {
      final ps = cam.value.previewSize;
      preview = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ps?.height ?? size,
          height: ps?.width ?? size,
          child: CameraPreview(cam),
        ),
      );
    } else {
      preview = Container(color: Colors.black);
    }
    final p = (_elapsed / widget.maxSeconds).clamp(0.0, 1.0);
    return Dialog(
      backgroundColor: c.bgTertiary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          key: const ValueKey('videoNoteRecorder'),
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipOval(child: preview),
                  CustomPaint(painter: _ProgressRing(p, c.danger)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${formatClock(_elapsed)} / ${formatClock(widget.maxSeconds)}',
              key: const ValueKey('videoNoteTime'),
              style: TextStyle(
                  color: c.text,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? videoNoteHint(_phase, widget.maxSeconds),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _error != null ? c.danger : c.textDim, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  key: const ValueKey('videoNoteCancel'),
                  onPressed: _close,
                  child: Text(tr(_phase == VideoNotePhase.review ? 'Delete' : 'Cancel')),
                ),
                if (_phase != VideoNotePhase.review)
                  Semantics(
                    button: true,
                    label: tr(_phase == VideoNotePhase.recording
                        ? 'Stop recording'
                        : 'Start recording'),
                    child: GestureDetector(
                      key: const ValueKey('videoNoteRec'),
                      onTap: cam == null ? null : _toggle,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.glassBorder),
                        ),
                        alignment: Alignment.center,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: c.danger,
                            borderRadius: BorderRadius.circular(
                                _phase == VideoNotePhase.recording ? 4 : 12),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.onceAllowed)
                  IconButton(
                    key: const ValueKey('videoNoteOnce'),
                    tooltip: tr('View once'),
                    isSelected: _once,
                    icon: Icon(Icons.looks_one_outlined,
                        color: _once ? c.primary : c.text),
                    onPressed: () => setState(() => _once = !_once),
                  ),
                OutlinedButton(
                  key: const ValueKey('videoNoteSend'),
                  onPressed: _phase == VideoNotePhase.review && _path != null
                      ? _send
                      : null,
                  child: Text(tr('Send'), style: TextStyle(color: c.primary)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRing extends CustomPainter {
  _ProgressRing(this.p, this.color);

  final double p;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (p <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6;
    final rect = Rect.fromLTWH(3, 3, size.width - 6, size.height - 6);
    canvas.drawArc(rect, -1.5707963, p * 6.2831853, false, paint);
  }

  @override
  bool shouldRepaint(_ProgressRing old) => old.p != p || old.color != color;
}

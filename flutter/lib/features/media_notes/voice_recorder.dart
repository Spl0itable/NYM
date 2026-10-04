import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'media_notes.dart';

abstract class VoiceRecorderBackend {
  Future<bool> hasPermission();
  Future<void> start(String path);
  Stream<double> levels(Duration interval);
  Future<String?> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class RecordVoiceBackend implements VoiceRecorderBackend {
  final AudioRecorder _r = AudioRecorder();

  @override
  Future<bool> hasPermission() => _r.hasPermission();

  @override
  Future<void> start(String path) => _r.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: MediaNoteLimits.voiceBitrate,
          sampleRate: 24000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );

  @override
  Stream<double> levels(Duration interval) =>
      _r.onAmplitudeChanged(interval).map((a) => dbfsToLevel(a.current));

  @override
  Future<String?> stop() => _r.stop();

  @override
  Future<void> cancel() => _r.cancel();

  @override
  Future<void> dispose() => _r.dispose();
}

final voiceRecorderBackendProvider =
    Provider<VoiceRecorderBackend Function()>((ref) => () => RecordVoiceBackend());

final voiceTempPathProvider = Provider<Future<String> Function()>((ref) => () async {
      final dir = await getTemporaryDirectory();
      return '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
    });

class RecordedVoice {
  const RecordedVoice({
    required this.path,
    required this.duration,
    required this.samples,
    required this.once,
  });

  final String path;
  final double duration;
  final List<double> samples;
  final bool once;

  String get mime => 'audio/mp4';
}

enum VoiceStartResult { started, denied, failed, cancelled }

const String kVoiceNotStarted = "the microphone hadn't started yet";
const String kVoiceNoData = 'no audio data came from the microphone';

class VoiceRecordingFailure implements Exception {
  const VoiceRecordingFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

class VoiceRecordingController extends ChangeNotifier {
  VoiceRecordingController({
    required this.backend,
    required this.tempPath,
    required this.maxSeconds,
    this.warnReason = '',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final VoiceRecorderBackend backend;
  final Future<String> Function() tempPath;
  final int maxSeconds;
  final String warnReason;
  final DateTime Function() _clock;

  static const Duration sampleEvery = Duration(milliseconds: 50);
  static const Duration tickEvery = Duration(milliseconds: 200);

  final List<double> samples = [];
  DateTime? _startedAt;
  double? _duration;
  bool locked = false;
  bool once = false;
  bool limitHit = false;
  bool stopped = false;
  double dragX = 0;
  String? _path;
  StreamSubscription<double>? _levels;
  Timer? _tick;
  Future<String?>? _stopping;

  double get elapsed {
    if (_duration != null) return _duration!;
    final s = _startedAt;
    if (s == null) return 0;
    return _clock().difference(s).inMilliseconds / 1000;
  }

  double get remaining => (maxSeconds - elapsed).clamp(0, maxSeconds).toDouble();

  Future<VoiceStartResult> start() async {
    try {
      if (!await backend.hasPermission()) {
        return stopped ? VoiceStartResult.cancelled : VoiceStartResult.denied;
      }
      if (stopped) return VoiceStartResult.cancelled;
      _path = await tempPath();
      if (stopped) return VoiceStartResult.cancelled;
      await backend.start(_path!);
    } catch (e) {
      if (stopped) return VoiceStartResult.cancelled;
      debugPrint('[voice] recorder failed to start: $e');
      return VoiceStartResult.failed;
    }
    if (stopped) {
      try {
        await backend.cancel();
      } catch (_) {}
      return VoiceStartResult.cancelled;
    }
    _startedAt = _clock();
    _levels = backend.levels(sampleEvery).listen((v) {
      samples.add(v);
    });
    _tick = Timer.periodic(tickEvery, (_) {
      if (!limitHit && elapsed >= maxSeconds) {
        limitHit = true;
        locked = true;
        _finish();
      }
      notifyListeners();
    });
    notifyListeners();
    return VoiceStartResult.started;
  }

  void lock() {
    locked = true;
    dragX = 0;
    notifyListeners();
  }

  void toggleOnce() {
    once = !once;
    notifyListeners();
  }

  void drag(double dx) {
    dragX = dx;
    notifyListeners();
  }

  Future<String?> _finish() {
    final existing = _stopping;
    if (existing != null) return existing;
    stopped = true;
    _duration = elapsed.clamp(0, maxSeconds).toDouble();
    _levels?.cancel();
    final Future<String?> f =
        _startedAt == null ? Future<String?>.value(null) : backend.stop();
    _stopping = f;
    return f;
  }

  Future<RecordedVoice?> stop({required bool send}) async {
    _tick?.cancel();
    final started = _startedAt != null;
    final path = await _finish() ?? _path;
    notifyListeners();
    if (!send) {
      await _deleteQuietly(path);
      return null;
    }
    if (!started) throw const VoiceRecordingFailure(kVoiceNotStarted);
    if (path == null || _sizeOf(path) == 0) {
      await _deleteQuietly(path);
      throw const VoiceRecordingFailure(kVoiceNoData);
    }
    return RecordedVoice(
        path: path, duration: _duration!, samples: List.of(samples), once: once);
  }

  static int _sizeOf(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _deleteQuietly(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _tick?.cancel();
    _levels?.cancel();
    backend.dispose();
    super.dispose();
  }
}

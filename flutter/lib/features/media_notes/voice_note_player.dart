import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/media_fallbacks.dart';
import '../toasts/toast_center.dart';
import '../toasts/toast_model.dart';
import 'media_note_files.dart';
import 'media_note_stores.dart';
import 'media_notes.dart';
import 'transcription_service.dart';

final activeMediaNoteProvider = StateProvider<Object?>((ref) => null);

const List<double> kVoiceBarHeights = <double>[
  2, 3, 4, 5, 6, 8, 9, 10, 12, 13, 15, 16, 18, 19, 21, 22,
];

int voiceBarStep(int level) => ((level.clamp(0, 63) / 63 * 15) + 0.5).floor();

List<int> voiceBarLevels(MediaNote note) => note.waveform.isNotEmpty
    ? note.waveform
    : List<int>.filled(MediaNoteLimits.waveformBars, 8);

bool canPlayVoiceMime(String mime, TargetPlatform platform) {
  final m = baseMime(mime);
  final apple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  if (apple && (m == 'audio/webm' || m == 'video/webm' || m == 'audio/ogg')) {
    return false;
  }
  return true;
}

String transcribeLanguage() =>
    PlatformDispatcher.instance.locale.toLanguageTag();

final modelClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

typedef VoiceNoteTempFile = Future<String> Function(
    MediaNote note, String? localPath);

final voiceNoteTempFileProvider =
    Provider<VoiceNoteTempFile>((ref) => (note, localPath) async {
          final bytes = localPath != null
              ? await MediaNoteFiles.readLocal(localPath)
              : await MediaNoteFiles.fetch(note.url);
          return MediaNoteFiles.writeTemp(bytes, note.mime);
        });

class VoiceNotePlayer extends ConsumerStatefulWidget {
  const VoiceNotePlayer({
    super.key,
    required this.note,
    this.localPath,
    this.maxWidth = 340,
  });

  final MediaNote note;
  final String? localPath;
  final double maxWidth;

  @override
  ConsumerState<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends ConsumerState<VoiceNotePlayer> {
  final Object _token = Object();
  AudioPlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  String? _failure;
  String? _tempPath;
  bool _sourceSet = false;
  String? _transcript;
  String? _transcriptNote;
  bool _transcribing = false;
  String? _modelStage;
  DateTime? _modelStarted;
  bool _modelCanceled = false;
  bool _modelRetry = false;
  Timer? _modelTicker;

  String get _key => widget.note.local || widget.localPath != null
      ? 'local:${widget.localPath ?? widget.note.url}'
      : widget.note.url;

  double get _total => _duration > Duration.zero
      ? _duration.inMilliseconds / 1000
      : (widget.note.duration ?? 0);

  @override
  void initState() {
    super.initState();
    final cached = ref.read(transcriptStoreProvider).get(_key);
    if (cached != null) _transcript = cached;
  }

  @override
  void dispose() {
    _modelTicker?.cancel();
    _modelCanceled = true;
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    MediaNoteFiles.deleteQuietly(_tempPath);
    super.dispose();
  }

  Future<AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _player = p;
    _subs.add(p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    }));
    _subs.add(p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(p.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    }));
    return p;
  }

  Future<bool> _setSource(AudioPlayer p) async {
    if (_sourceSet) return true;
    if (!canPlayVoiceMime(widget.note.mime, defaultTargetPlatform)) {
      setState(() => _failure = tr("Can't play this format here"));
      return false;
    }
    final local = widget.localPath;
    if (local != null) {
      final bytes = await MediaNoteFiles.readLocal(local);
      _tempPath = await MediaNoteFiles.writeTemp(bytes, widget.note.mime);
      await p.setSource(DeviceFileSource(_tempPath!, mimeType: widget.note.mime));
      _sourceSet = true;
      return true;
    }
    final urls = <String>[
      widget.note.url,
      ...ref.read(mediaFallbacksProvider).fallbacksFor(widget.note.url),
    ];
    for (final u in urls) {
      try {
        await p.setSource(UrlSource(proxiedMedia(u), mimeType: widget.note.mime));
        _sourceSet = true;
        return true;
      } catch (_) {}
    }
    setState(() => _failure = tr("Couldn't load"));
    return false;
  }

  Future<void> _toggle() async {
    if (_failure != null) return;
    final p = await _ensurePlayer();
    if (_playing) {
      await p.pause();
      return;
    }
    ref.read(activeMediaNoteProvider.notifier).state = _token;
    setState(() => _loading = true);
    try {
      if (!await _setSource(p)) return;
      await p.setPlaybackRate(ref.read(voiceSpeedProvider));
      await p.resume();
    } catch (_) {
      if (mounted) setState(() => _failure = tr("Couldn't load"));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _seek(double fraction) async {
    final f = fraction.clamp(0.0, 1.0);
    final p = await _ensurePlayer();
    if (!_sourceSet) {
      await _toggle();
    }
    final totalMs = _duration > Duration.zero
        ? _duration.inMilliseconds
        : ((widget.note.duration ?? 0) * 1000).round();
    if (totalMs <= 0) return;
    final target = Duration(milliseconds: (totalMs * f).round());
    await p.seek(target);
    if (mounted) setState(() => _position = target);
  }

  Future<void> _cycleSpeed() async {
    final next = ref.read(voiceSpeedProvider.notifier).cycle();
    final p = _player;
    if (p != null && _playing) await p.setPlaybackRate(next);
  }

  Future<void> _transcribe({bool consented = false}) async {
    if (_transcribing || _modelStage != null) return;
    final cached = ref.read(transcriptStoreProvider).get(_key);
    if (cached != null) {
      setState(() => _transcript = cached);
      return;
    }
    final svc = ref.read(transcriptionServiceProvider);
    final lang = transcribeLanguage();
    final avail = await svc.availability(lang);
    if (!mounted) return;
    if (!avail.usable) {
      setState(() => _transcriptNote = tr(avail.reason, {'lang': lang}));
      return;
    }
    if (avail.status != TranscribeStatus.available) {
      if (!consented && avail.status == TranscribeStatus.downloadable) {
        final ok = await showAppConfirm(
          context,
          tr('Transcription runs on this device. A speech model for {lang} needs to be downloaded once. The audio never leaves this device.',
              {'lang': lang}),
          okLabel: tr('Download model'),
        );
        if (!ok || !mounted) return;
      }
      if (!await _downloadModel(svc, lang)) return;
    }
    setState(() {
      _transcribing = true;
      _transcriptNote = tr('Transcribing on this device…');
    });
    String? path;
    try {
      path = await ref.read(voiceNoteTempFileProvider)(
          widget.note, widget.localPath);
      final text = await svc.transcribe(path, lang);
      ref.read(transcriptStoreProvider).set(_key, text);
      if (mounted) {
        setState(() {
          _transcript = text;
          _transcriptNote = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _transcriptNote = tr("Couldn't transcribe this message."));
      }
    } finally {
      await MediaNoteFiles.deleteQuietly(path);
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<bool> _downloadModel(TranscriptionService svc, String lang) async {
    final limits = ref.read(modelDownloadLimitsProvider);
    final now = ref.read(modelClockProvider);
    final started = now();
    setState(() {
      _modelStage = 'starting';
      _modelStarted = started;
      _modelCanceled = false;
      _modelRetry = false;
      _transcriptNote = null;
    });
    _modelTicker?.cancel();
    _modelTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    bool? installResult;
    String? status;
    var sawDownloading = false;
    svc.install(lang).then((ok) {
      if (!ok) installResult = false;
    }, onError: (Object _) {
      installResult = false;
    });
    const terminal = {'done', 'failed', 'stalled', 'timeout', 'canceled'};
    String stage;
    while (true) {
      stage = modelDownloadStage(
        status: status,
        installResult: installResult,
        elapsedMs: now().difference(started).inMilliseconds,
        sawDownloading: sawDownloading,
        canceled: _modelCanceled,
        limits: limits,
      );
      if (!mounted) {
        _modelTicker?.cancel();
        return false;
      }
      if (terminal.contains(stage)) break;
      setState(() => _modelStage = stage);
      await Future<void>.delayed(Duration(milliseconds: limits.pollMs));
      if (_modelCanceled || installResult != null || !mounted) continue;
      try {
        status = transcribeStatusName((await svc.availability(lang)).status);
      } catch (_) {}
      if (status == 'downloading') sawDownloading = true;
    }
    _modelTicker?.cancel();
    _modelTicker = null;
    if (stage == 'done') {
      setState(() => _modelStage = 'preparing');
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return false;
      setState(() => _modelStage = null);
      return true;
    }
    final String note;
    if (stage == 'canceled') {
      note = tr(kModelCanceled);
    } else if (stage == 'stalled') {
      note = tr(kModelStalled);
    } else if (stage == 'timeout') {
      note = tr(kModelTimeout);
    } else {
      note = tr(kModelFailed);
    }
    setState(() {
      _modelStage = null;
      _transcriptNote = note;
      _modelRetry = stage != 'canceled';
    });
    if (stage != 'canceled') showToast(note, kind: ToastKind.error);
    return false;
  }

  String _modelStageText(String stage) => switch (stage) {
        'downloading' => tr(kModelDownloading),
        'preparing' => tr(kModelPreparing),
        _ => tr(kModelStarting),
      };

  Widget _modelPanel(NymColors c) {
    final stage = _modelStageText(_modelStage!);
    final elapsed = _modelStarted == null
        ? 0.0
        : ref.read(modelClockProvider)().difference(_modelStarted!).inMilliseconds /
            1000;
    final clock = formatClock(elapsed);
    return Container(
      key: const ValueKey('modelDownload'),
      constraints: const BoxConstraints(maxWidth: 260),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.glassBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(stage,
                      style: TextStyle(color: c.text, fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Text(clock,
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              minHeight: 4,
              color: c.primary,
              backgroundColor: c.primaryA(0.15),
              semanticsLabel: tr(kModelDownloadLabel),
              semanticsValue: '$stage $clock',
            ),
          ),
          const SizedBox(height: 6),
          _SmallButton(
            key: const ValueKey('modelCancel'),
            label: tr('Cancel'),
            onTap: () => setState(() => _modelCanceled = true),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    ref.listen<Object?>(activeMediaNoteProvider, (_, next) {
      if (next != _token && _playing) _player?.pause();
    });
    final speed = ref.watch(voiceSpeedProvider);
    final levels = voiceBarLevels(widget.note);
    final total = _total;
    final pos = _position.inMilliseconds / 1000;
    final frac = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
    final idle = !_playing && _position == Duration.zero;
    final played = idle ? 0 : (frac * levels.length).round();
    final timeText = _failure ?? formatClock(idle ? total : pos);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Container(
        key: const ValueKey('voiceNote'),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.primaryA(0.06),
          border: Border.all(color: c.glassBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  label: tr('Play voice message'),
                  child: GestureDetector(
                    key: const ValueKey('voicePlay'),
                    onTap: _toggle,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.primaryA(0.12),
                        border: Border.all(color: c.primaryA(0.35)),
                      ),
                      alignment: Alignment.center,
                      child: _loading
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: c.primary))
                          : Icon(_playing ? Icons.pause : Icons.play_arrow,
                              color: c.primary, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, box) => Semantics(
                      slider: true,
                      label: tr('Seek'),
                      value: '${(frac * 100).round()}',
                      child: GestureDetector(
                        key: const ValueKey('voiceWave'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => box.maxWidth > 0
                            ? _seek(d.localPosition.dx / box.maxWidth)
                            : null,
                        onHorizontalDragUpdate: (d) => box.maxWidth > 0 && _sourceSet
                            ? _seek(d.localPosition.dx / box.maxWidth)
                            : null,
                        child: SizedBox(
                          height: 26,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              for (var i = 0; i < levels.length; i++)
                                Container(
                                  width: 3,
                                  height: kVoiceBarHeights[voiceBarStep(levels[i])],
                                  decoration: BoxDecoration(
                                    color: i < played ? c.primary : c.textDim,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeText,
                  key: const ValueKey('voiceTime'),
                  style: TextStyle(
                    color: _failure != null ? c.danger : c.textDim,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                _SmallButton(
                  key: const ValueKey('voiceSpeed'),
                  label: speedLabel(speed),
                  semantic: tr('Playback speed'),
                  onTap: _cycleSpeed,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_transcript == null && _modelStage == null && !_modelRetry)
                    _SmallButton(
                      key: const ValueKey('voiceTranscribe'),
                      label: tr('Transcribe'),
                      onTap: _transcribe,
                    ),
                  if (_modelStage != null) _modelPanel(c),
                  if (_transcript != null || _transcriptNote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _transcript == null
                            ? _transcriptNote!
                            : (_transcript!.isEmpty
                                ? tr('No speech found.')
                                : _transcript!),
                        key: const ValueKey('voiceTranscript'),
                        style: TextStyle(
                          color: _transcript == null ? c.textDim : c.text,
                          fontStyle: _transcript == null
                              ? FontStyle.italic
                              : FontStyle.normal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (_modelRetry && _modelStage == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _SmallButton(
                        key: const ValueKey('modelRetry'),
                        label: tr('Retry'),
                        onTap: () {
                          setState(() => _modelRetry = false);
                          _transcribe(consented: true);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    super.key,
    required this.label,
    required this.onTap,
    this.semantic,
  });

  final String label;
  final VoidCallback onTap;
  final String? semantic;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      label: semantic,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minWidth: 38),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: c.glassBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: c.text,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ),
    );
  }
}


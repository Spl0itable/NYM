// Inline audio player; nothing is fetched until the first tap, and a load failure falls back to download.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/nym_colors.dart';
import '../../i18n/i18n.dart';
import '../../../core/utils/safe_url.dart';
import 'audio_playback.dart';
import 'media_source.dart';
import 'message_content.dart' show proxiedMedia;
import 'playback_keeper.dart';

const double _kAudioRadius = 12;

/// Columns pass a smaller cap via [maxWidth].
const double _kAudioMaxWidth = 340;

class AudioMessage extends StatefulWidget {
  const AudioMessage({
    super.key,
    required this.url,
    this.fileName = '',
    this.maxWidth = _kAudioMaxWidth,
    this.playbackScope,
  });

  final String url;

  final String fileName;

  final double maxWidth;

  final String? playbackScope;

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  AudioPlayback? _session;
  bool _loading = false;
  bool _failed = false;

  Duration get _position => _session?.position ?? Duration.zero;

  Duration get _duration => _session?.duration ?? Duration.zero;

  bool get _playing => _session?.playing ?? false;

  String? get _source => _session?.source;

  String? _keyOf(AudioMessage w) {
    final scope = w.playbackScope;
    if (scope == null) return null;
    return PlaybackKeeper.keyFor(scope, w.url);
  }

  @override
  void initState() {
    super.initState();
    _bind(_keyOf(widget));
  }

  @override
  void didUpdateWidget(AudioMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = _keyOf(oldWidget);
    final key = _keyOf(widget);
    if (old == key && oldWidget.url == widget.url) return;
    _unbind(old);
    _failed = false;
    _bind(key);
  }

  @override
  void dispose() {
    _unbind(_keyOf(widget));
    super.dispose();
  }

  void _bind(String? key) {
    AudioPlayback.keeper.watch(key, _onStarted);
    final s = AudioPlayback.keeper.join(key, this);
    if (s != null) _attach(s);
  }

  void _unbind(String? key) {
    AudioPlayback.keeper.unwatch(key, _onStarted);
    final s = _session;
    _session = null;
    if (s == null) return;
    s.removeListener(_onSession);
    AudioPlayback.keeper.leave(s, this);
  }

  void _attach(AudioPlayback s) {
    if (identical(_session, s)) return;
    s.addListener(_onSession);
    _session = s;
  }

  void _onStarted() {
    if (!mounted || _session != null) return;
    final s = AudioPlayback.keeper.join(_keyOf(widget), this);
    if (s != null) setState(() => _attach(s));
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  AudioPlayback _ensureSession() {
    final existing = _session;
    if (existing != null) return existing;
    final key = _keyOf(widget);
    final s = AudioPlayback.keeper
        .start(key, this, () => AudioPlayback(key, AudioPlayer()));
    _attach(s);
    return s;
  }

  Future<void> _toggle() async {
    if (_failed) {
      _open();
      return;
    }
    final s = _ensureSession();
    final p = s.player;
    if (s.playing) {
      await p.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      final source = s.source;
      if (s.position > Duration.zero && s.position < s.duration) {
        await p.resume();
      } else if (source != null) {
        await p.play(UrlSource(source));
      } else {
        final opened =
            await openMediaSource([widget.url], (u) => _tryPlay(p, u));
        s.source = opened;
        if (opened == null && mounted) setState(() => _failed = true);
      }
    } catch (_) {
      // Keep the download route working rather than leaving a dead bar.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _tryPlay(AudioPlayer p, String url) async {
    try {
      await p.play(UrlSource(url));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _seek(double fraction) async {
    final s = _session;
    if (s == null || s.duration <= Duration.zero) return;
    final target =
        Duration(milliseconds: (s.duration.inMilliseconds * fraction).round());
    await s.player.seek(target);
    s.position = target;
    if (mounted) setState(() {});
  }

  void _open() {
    launchSafeUrl(_source ?? proxiedMedia(widget.url));
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final total = _duration.inMilliseconds;
    final progress =
        total > 0 ? (_position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: c.bgTertiary,
              border: Border.all(color: c.glassBorder),
              borderRadius: BorderRadius.circular(_kAudioRadius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PlayButton(
                  playing: _playing,
                  loading: _loading,
                  failed: _failed,
                  color: c.primary,
                  onTap: _toggle,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, box) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => box.maxWidth > 0
                          ? _seek(d.localPosition.dx / box.maxWidth)
                          : null,
                      child: SizedBox(
                        height: 18,
                        child: Align(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 4,
                              backgroundColor: c.glassBorder,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(c.primary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  total > 0
                      ? '${_clock(_position)} / ${_clock(_duration)}'
                      : _clock(_position),
                  style: TextStyle(
                    color: c.textDim,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _open,
            child: Text(
              widget.fileName.isEmpty
                  ? tr('Download')
                  : '${tr('Download')} ${widget.fileName}',
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                decoration: TextDecoration.underline,
                decorationColor: c.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.failed,
    required this.color,
    required this.onTap,
  });

  final bool playing;
  final bool loading;
  final bool failed;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 26,
        height: 26,
        child: loading
            ? Padding(
                padding: const EdgeInsets.all(5),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              )
            : Icon(
                failed
                    ? Icons.open_in_new
                    : (playing ? Icons.pause : Icons.play_arrow),
                color: color,
                size: 22,
              ),
      ),
    );
  }
}

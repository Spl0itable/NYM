// Inline audio player for message media. The bot's ?speak replies (and any
// audio link someone pastes) used to render as a bare URL; this gives them a
// transport bar with the file offered underneath, in both the single-chat and
// columns views — the PWA's `.audio-container` (`message-format.js`,
// `styles-chat.css`) rendered natively.
//
// Playback is lazy: nothing is fetched until the first tap, so a channel full
// of audio links costs no bandwidth on render. A source that fails to load
// falls back to the download affordance rather than becoming a dead bar.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../i18n/i18n.dart';

/// `--radius-sm` (`styles-core.css:87`).
const double _kAudioRadius = 12;

/// Matches `.message-content .audio-container { max-width: 340px }`; columns
/// pass a smaller cap via [maxWidth].
const double _kAudioMaxWidth = 340;

class AudioMessage extends StatefulWidget {
  const AudioMessage({
    super.key,
    required this.url,
    this.fileName = '',
    this.maxWidth = _kAudioMaxWidth,
  });

  /// Directly-playable URL (the formatter has already proxied it).
  final String url;

  /// Basename shown on the download link; falls back to a generic label.
  final String fileName;

  final double maxWidth;

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  AudioPlayer? _player;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _failed = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    final p = AudioPlayer();
    _player = p;
    p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    p.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  Future<void> _toggle() async {
    if (_failed) {
      _open();
      return;
    }
    await _ensurePlayer();
    final p = _player!;
    if (_playing) {
      await p.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      if (_position > Duration.zero && _position < _duration) {
        await p.resume();
      } else {
        await p.play(UrlSource(widget.url));
      }
    } catch (_) {
      // Unsupported codec or an unreachable source: keep the download route
      // working instead of leaving a bar that does nothing.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _seek(double fraction) async {
    if (_duration <= Duration.zero) return;
    await _ensurePlayer();
    final target =
        Duration(milliseconds: (_duration.inMilliseconds * fraction).round());
    await _player!.seek(target);
    if (mounted) setState(() => _position = target);
  }

  void _open() {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
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

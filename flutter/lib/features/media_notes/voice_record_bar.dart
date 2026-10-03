import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'media_notes.dart';
import 'voice_note_player.dart' show kVoiceBarHeights;
import 'voice_recorder.dart';

const int kVoiceHoldMs = 250;
const double kVoiceCancelDx = 80;
const double kVoiceLockDy = 60;

List<int> recordingLevels(List<double> samples) {
  final recent = samples.length > 32 ? samples.sublist(samples.length - 32) : samples;
  return recent.map((v) => ((v.clamp(0.0, 1.0) * 15) + 0.5).floor()).toList();
}

String voiceRecordHint(VoiceRecordingController c) {
  if (c.limitHit) {
    return tr('Limit reached ({max}). Send or delete.',
        {'max': formatClock(c.maxSeconds)});
  }
  if (c.remaining <= 10) return tr('{s} s left', {'s': c.remaining.ceil()});
  if (c.warnReason.isNotEmpty) return tr(c.warnReason);
  if (c.locked) return tr('Recording hands-free');
  return '‹ ${tr('Slide to cancel')}  ·  ↑ ${tr('Slide up to lock')}';
}

class VoiceRecordBar extends StatelessWidget {
  const VoiceRecordBar({
    super.key,
    required this.controller,
    required this.onCancel,
    required this.onSend,
    required this.onToggleOnce,
    required this.onceAllowed,
  });

  final VoiceRecordingController controller;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final VoidCallback onToggleOnce;
  final bool onceAllowed;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final rec = controller;
        final warn = rec.remaining <= 10 || rec.limitHit;
        final levels = recordingLevels(rec.samples);
        return Transform.translate(
          offset: Offset(rec.dragX < 0 ? rec.dragX : 0, 0),
          child: Container(
            key: const ValueKey('voiceRecBar'),
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.bgTertiary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.glassBorder),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('voiceRecCancel'),
                  tooltip: tr('Delete recording'),
                  icon: Icon(Icons.delete_outline, color: c.text, size: 18),
                  onPressed: onCancel,
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: c.danger, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  '${formatClock(rec.elapsed)} / ${formatClock(rec.maxSeconds)}',
                  key: const ValueKey('voiceRecTime'),
                  style: TextStyle(
                    color: warn ? c.warning : c.text,
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 24,
                    child: Row(
                      children: [
                        for (final l in levels)
                          Container(
                            width: 3,
                            height: kVoiceBarHeights[l.clamp(0, 15)],
                            margin: const EdgeInsets.only(right: 2),
                            decoration: BoxDecoration(
                              color: c.danger,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    voiceRecordHint(rec),
                    key: const ValueKey('voiceRecHint'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: warn ? c.warning : c.textDim, fontSize: 12),
                  ),
                ),
                if (rec.locked && onceAllowed)
                  IconButton(
                    key: const ValueKey('voiceRecOnce'),
                    tooltip: tr('View once'),
                    isSelected: rec.once,
                    icon: Icon(Icons.looks_one_outlined,
                        color: rec.once ? c.primary : c.text, size: 18),
                    onPressed: onToggleOnce,
                  ),
                if (rec.locked)
                  IconButton(
                    key: const ValueKey('voiceRecSend'),
                    tooltip: tr('Send voice message'),
                    icon: Icon(Icons.send, color: c.primary, size: 18),
                    onPressed: onSend,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class VoiceMicGesture extends StatefulWidget {
  const VoiceMicGesture({
    super.key,
    required this.child,
    required this.onStart,
    required this.onLock,
    required this.onCancel,
    required this.onRelease,
    required this.onDrag,
    required this.recording,
  });

  final Widget child;
  final Future<bool> Function() onStart;
  final VoidCallback onLock;
  final VoidCallback onCancel;
  final VoidCallback onRelease;
  final ValueChanged<double> onDrag;
  final bool Function() recording;

  @override
  State<VoiceMicGesture> createState() => _VoiceMicGestureState();
}

class _VoiceMicGestureState extends State<VoiceMicGesture> {
  Offset? _origin;
  DateTime? _downAt;
  bool _tracking = false;

  Future<void> _down(PointerDownEvent e) async {
    if (widget.recording()) return;
    _origin = e.position;
    _downAt = DateTime.now();
    _tracking = true;
    final started = await widget.onStart();
    if (!started) _tracking = false;
  }

  void _move(PointerMoveEvent e) {
    final o = _origin;
    if (!_tracking || o == null || !widget.recording()) return;
    final dx = e.position.dx - o.dx;
    final dy = e.position.dy - o.dy;
    if (dx < -kVoiceCancelDx) {
      _tracking = false;
      widget.onCancel();
      return;
    }
    if (dy < -kVoiceLockDy) {
      _tracking = false;
      widget.onLock();
      return;
    }
    widget.onDrag(dx);
  }

  void _up(PointerUpEvent e) {
    if (!_tracking) return;
    _tracking = false;
    final at = _downAt;
    if (at != null &&
        DateTime.now().difference(at).inMilliseconds < kVoiceHoldMs) {
      widget.onLock();
      return;
    }
    widget.onRelease();
  }

  void _cancel(PointerCancelEvent e) {
    if (!_tracking) return;
    _tracking = false;
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.space) {
          return KeyEventResult.ignored;
        }
        if (!widget.recording()) {
          widget.onStart().then((ok) {
            if (ok) widget.onLock();
          });
        }
        return KeyEventResult.handled;
      },
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: widget.child,
      ),
    );
  }
}

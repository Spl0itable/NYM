import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A one-shot reaction "burst" overlay played when the user adds a reaction
/// (reactions.js `_playReactionBurst`, styles-features.css `.reaction-burst` /
/// `.reaction-spark`, keyframes `reactionBurst` (0.85s) / `reactionSpark`
/// (0.7s)). The emoji pops up and floats while 10 radial sparks fan out.
///
/// Call [ReactionBurst.play] with a global anchor point (the badge centre) to
/// spawn it into the root [Overlay]; it removes itself after ~900ms.
class ReactionBurst {
  ReactionBurst._();

  static const _durationMs = 900;
  static const _sparkCount = 10;

  /// Spawns a burst centred at [globalCenter] showing [emoji].
  static void play(BuildContext context, Offset globalCenter, String emoji) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BurstWidget(center: globalCenter, emoji: emoji),
    );
    overlay.insert(entry);
    Future<void>.delayed(const Duration(milliseconds: _durationMs), () {
      if (entry.mounted) entry.remove();
    });
  }
}

class _Spark {
  _Spark(this.dx, this.dy, this.delay);
  final double dx;
  final double dy;
  final double delay; // 0..1 fraction of the spark animation window
}

class _BurstWidget extends StatefulWidget {
  const _BurstWidget({required this.center, required this.emoji});
  final Offset center;
  final String emoji;

  @override
  State<_BurstWidget> createState() => _BurstWidgetState();
}

class _BurstWidgetState extends State<_BurstWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Spark> _sparks;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    _sparks = List.generate(ReactionBurst._sparkCount, (i) {
      final angle = (i / ReactionBurst._sparkCount) * math.pi * 2 +
          (rng.nextDouble() - 0.5) * 0.4;
      final dist = 22 + rng.nextDouble() * 22;
      return _Spark(
        math.cos(angle) * dist,
        math.sin(angle) * dist,
        // animationDelay up to 40ms over a 900ms window.
        (rng.nextDouble() * 40) / ReactionBurst._durationMs,
      );
    });
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: ReactionBurst._durationMs),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Burst keyframes span 0.85s of the 0.9s window.
          final burstT = (_c.value * 900 / 850).clamp(0.0, 1.0);
          return Stack(
            children: [
              ..._buildSparks(),
              _buildEmoji(burstT),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmoji(double t) {
    // reactionBurst keyframes: scale 0 → 1.5 → 1.15 → 0.5,
    // y offset 0 → 0 → -20% → -130%, opacity 0 → 1 → 1 → 0.
    double scale;
    double yShift; // in multiples of the glyph height (~45px)
    double opacity;
    if (t < 0.25) {
      final f = t / 0.25;
      scale = _lerp(0, 1.5, f);
      yShift = 0;
      opacity = _lerp(0, 1, f);
    } else if (t < 0.55) {
      final f = (t - 0.25) / 0.30;
      scale = _lerp(1.5, 1.15, f);
      yShift = _lerp(0, -0.20, f);
      opacity = 1;
    } else {
      final f = (t - 0.55) / 0.45;
      scale = _lerp(1.15, 0.5, f);
      yShift = _lerp(-0.20, -1.30, f);
      opacity = _lerp(1, 0, f);
    }
    const glyph = 45.0;
    return Positioned(
      left: widget.center.dx - glyph / 2,
      top: widget.center.dy - glyph / 2 + yShift * glyph,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          child: Text(
            widget.emoji,
            style: const TextStyle(
              fontSize: glyph,
              height: 1,
              shadows: [
                Shadow(color: Color(0x73FFC864), blurRadius: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSparks() {
    // reactionSpark spans 0.7s of the 0.9s window.
    return _sparks.map((s) {
      final raw = ((_c.value - s.delay) * 900 / 700).clamp(0.0, 1.0);
      final scale = _lerp(0.5, 0.15, raw);
      final opacity = _lerp(1, 0, raw);
      final x = widget.center.dx + s.dx * raw;
      final y = widget.center.dy + s.dy * raw;
      return Positioned(
        left: x - 2.5,
        top: y - 2.5,
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xFFFFD86B), Color(0xFFFF7B1F), Color(0x00FF7B1F)],
                  stops: [0.0, 0.7, 1.0],
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t.clamp(0.0, 1.0);
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../messages/format/message_content.dart';

/// One-shot reaction burst overlay: the emoji pops while 10 sparks fan out; removes itself after ~900ms.
class ReactionBurst {
  ReactionBurst._();

  static const _durationMs = 900;
  static const _sparkCount = 10;

  static void play(BuildContext context, Offset globalCenter, String emoji) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
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

  // Mounted reaction badges register here so bursts anchor at the badge's live position.

  static final Map<String, GlobalKey> _badges = <String, GlobalKey>{};

  static String _badgeKeyOf(String messageId, String emoji) =>
      '$messageId|$emoji';

  static void registerBadge(String messageId, String emoji, GlobalKey key) {
    _badges[_badgeKeyOf(messageId, emoji)] = key;
  }

  /// Removes a registration only if it still points at [key]; a replacement badge may have re-registered first.
  static void unregisterBadge(String messageId, String emoji, GlobalKey key) {
    final k = _badgeKeyOf(messageId, emoji);
    if (identical(_badges[k], key)) _badges.remove(k);
  }

  static Offset? badgeCenter(String messageId, String emoji) {
    final key = _badges[_badgeKeyOf(messageId, emoji)];
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// Bursts on the badge after this frame's layout, else at [fallbackCenter], else silently skips.
  static void playAtBadge(
    BuildContext context,
    String messageId,
    String emoji, {
    Offset? fallbackCenter,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final center = badgeCenter(messageId, emoji) ?? fallbackCenter;
      if (center == null) return;
      play(context, center, emoji);
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
        // Delay up to 40ms over the 900ms window.
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
    // The root Overlay has no Material ancestor; without one the glyph gets the debug yellow underline.
    return Material(
      type: MaterialType.transparency,
      child: IgnorePointer(
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
      ),
    );
  }

  /// Springy overshoot curve, applied within each keyframe segment like CSS.
  static const Cubic _burstEase = Cubic(0.34, 1.56, 0.64, 1);

  Widget _buildEmoji(double t) {
    // Keyframes: scale 0→1.5→1.15→0.5, rotate -25°→8°→-4°→0, y 0→0→-20%→-80% of glyph, opacity 0→1→1→0.
    double scale;
    double yShift; // in multiples of the glyph height (~45px)
    double opacity;
    double rotationDeg;
    if (t < 0.25) {
      final f = _burstEase.transform(t / 0.25);
      scale = _lerp(0, 1.5, f);
      yShift = 0;
      opacity = _lerp(0, 1, f);
      rotationDeg = _lerp(-25, 8, f);
    } else if (t < 0.55) {
      final f = _burstEase.transform((t - 0.25) / 0.30);
      scale = _lerp(1.5, 1.15, f);
      yShift = _lerp(0, -0.20, f);
      opacity = 1;
      rotationDeg = _lerp(8, -4, f);
    } else {
      final f = _burstEase.transform((t - 0.55) / 0.45);
      scale = _lerp(1.15, 0.5, f);
      yShift = _lerp(-0.20, -0.80, f);
      opacity = _lerp(1, 0, f);
      rotationDeg = _lerp(-4, 0, f);
    }
    const glyph = 45.0;
    return Positioned(
      left: widget.center.dx - glyph / 2,
      top: widget.center.dy - glyph / 2 + yShift * glyph,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: rotationDeg * math.pi / 180,
          child: Transform.scale(
            scale: scale,
            // Exact `:code:` reactions render as a 45x45 image; unicode falls through to text.
            child: InlineEmojiText(
              text: widget.emoji,
              wholeStringOnly: true,
              emojiSize: glyph,
              emojiMargin: EdgeInsets.zero,
              emojiAlignment: PlaceholderAlignment.top,
              style: const TextStyle(
                fontSize: glyph,
                height: 1,
                decoration: TextDecoration.none,
                shadows: [
                  Shadow(color: Color(0x73FFC864), blurRadius: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSparks() {
    // Sparks span 0.7s of the 0.9s window with ease-out.
    return _sparks.map((s) {
      final raw = ((_c.value - s.delay) * 900 / 700).clamp(0.0, 1.0);
      final eased = Curves.easeOut.transform(raw);
      final scale = _lerp(0.5, 0.15, eased);
      final opacity = _lerp(1, 0, eased);
      final x = widget.center.dx + s.dx * eased;
      final y = widget.center.dy + s.dy * eased;
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
                  colors: [
                    Color(0xFFFFD86B),
                    Color(0xFFFF7B1F),
                    Color(0x00FF7B1F)
                  ],
                  stops: [0.0, 0.7, 1.0],
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  // Unclamped so the overshoot easing can spring past keyframe targets.
  double _lerp(double a, double b, double t) => a + (b - a) * t;
}

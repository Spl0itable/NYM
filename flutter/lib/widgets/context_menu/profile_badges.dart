import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../common/nym_tooltip.dart';

/// The blue verified checkmark badge shown after a verified developer or bot nym.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 20, this.tooltip});

  final double size;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.nym.isLight
            ? const Color(0xFF1A8CD8)
            : const Color(0xFF1DA1F2),
        shape: BoxShape.circle,
      ),
      // The check is drawn, not a Text glyph: Flutter's U+2713 fallback font ignores weight and renders thinner.
      child: CustomPaint(
        size: Size.square(size),
        painter: _CheckPainter(scale: size / 20.0),
      ),
    );
    final t = tooltip;
    return (t == null || t.isEmpty) ? badge : NymTooltip(message: t, child: badge);
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.scale});

  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(6.0 * s, 10.6 * s)
      ..lineTo(8.9 * s, 13.4 * s)
      ..lineTo(14.2 * s, 6.8 * s);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter oldDelegate) =>
      oldDelegate.scale != scale;
}

/// The friend badge glyph shown after a friend's nym.
class FriendBadge extends StatelessWidget {
  const FriendBadge({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color =
        context.nym.isLight ? const Color(0xFF0288D1) : const Color(0xFF4FC3F7);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FriendBadgePainter(color)),
    );
  }
}

class _FriendBadgePainter extends CustomPainter {
  const _FriendBadgePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 16.0;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawCircle(Offset(6 * s, 5 * s), 2.5 * s, fill);

    final body = Path()
      ..moveTo(1.5 * s, 14 * s)
      ..cubicTo(1.5 * s, 10.5 * s, 3.5 * s, 9 * s, 6 * s, 9 * s)
      ..cubicTo(8.5 * s, 9 * s, 10.5 * s, 10.5 * s, 10.5 * s, 14 * s);
    canvas.drawPath(body, fill);

    canvas.drawLine(Offset(13 * s, 6 * s), Offset(13 * s, 10 * s), stroke);
    canvas.drawLine(Offset(11 * s, 8 * s), Offset(15 * s, 8 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _FriendBadgePainter oldDelegate) =>
      oldDelegate.color != color;
}

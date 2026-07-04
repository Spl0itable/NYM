import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// The blue verified checkmark badge (`.verified-badge`, styles-components.css
/// :1382-1411): a 20×20 #1DA1F2 circle (light mode darkens it to #1a8cd8,
/// styles-themes-responsive.css:76-78) with a white ✓ (12px, w700). Rendered
/// after the nym for `isVerifiedDeveloper` / `isVerifiedBot`
/// (ui-context.js:407-411). `margin-left:4px; margin-right:2px` is applied by
/// the caller's row gap.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 20, this.tooltip});

  final double size;

  /// Optional hover/long-press title — the PWA sets `badge.title` to
  /// `verifiedDeveloper.title` ("Nymchat Developer") or "Nymchat Bot" depending
  /// on the holder (autocomplete.js:430). Null/empty = no tooltip (keeps the
  /// existing callers that render a bare badge unchanged).
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // `body.light-mode .verified-badge::before { background: #1a8cd8 }`.
        color: context.nym.isLight
            ? const Color(0xFF1A8CD8)
            : const Color(0xFF1DA1F2),
        shape: BoxShape.circle,
      ),
      // The ✓ is DRAWN, not a Text glyph: the CSS `content:"✓"` at
      // font-weight 700 gets faux-bolded by the browser, while Flutter's
      // U+2713 falls back to a symbol font that ignores the weight — the
      // badge check rendered visibly thinner/different from the PWA's.
      child: CustomPaint(
        size: Size.square(size),
        painter: _CheckPainter(scale: size / 20.0),
      ),
    );
    final t = tooltip;
    return (t == null || t.isEmpty) ? badge : Tooltip(message: t, child: badge);
  }
}

/// The badge's bold white check, matching the PWA's 12px w700 "✓" inside the
/// 20px circle. Authored in the 20×20 badge box and scaled uniformly.
class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.scale});

  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      // ≈ the stroke weight of a bold 12px ✓.
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

/// The friend badge (`.friend-badge`, styles-features.css:1483-1495): a
/// people-with-check glyph in #4fc3f7 (light mode darkens it to #0288d1,
/// `body.light-mode .friend-badge`, styles-themes-responsive.css:1300-1307),
/// appended after the nym for friends (ui-context.js:412-414). Drawn to match
/// the PWA's inline SVG (16×16 viewBox: head circle + shoulders arc + a small
/// plus to the right).
class FriendBadge extends StatelessWidget {
  const FriendBadge({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    // `body.light-mode .friend-badge svg { fill: #0288d1; stroke: #0288d1 }`.
    final color = context.nym.isLight
        ? const Color(0xFF0288D1)
        : const Color(0xFF4FC3F7);
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
    // The PWA SVG is authored in a 16×16 box; scale uniformly to [size].
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

    // <circle cx="6" cy="5" r="2.5" /> — head (filled).
    canvas.drawCircle(Offset(6 * s, 5 * s), 2.5 * s, fill);

    // <path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /> —
    // shoulders arc (filled body in the PWA via fill="currentColor").
    final body = Path()
      ..moveTo(1.5 * s, 14 * s)
      ..cubicTo(1.5 * s, 10.5 * s, 3.5 * s, 9 * s, 6 * s, 9 * s)
      ..cubicTo(8.5 * s, 9 * s, 10.5 * s, 10.5 * s, 10.5 * s, 14 * s);
    canvas.drawPath(body, fill);

    // The two check lines forming a "+" to the right of the head:
    // <line x1="13" y1="6" x2="13" y2="10" /> and <line x1="11" y1="8" x2="15" y2="8" />.
    canvas.drawLine(Offset(13 * s, 6 * s), Offset(13 * s, 10 * s), stroke);
    canvas.drawLine(Offset(11 * s, 8 * s), Offset(15 * s, 8 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _FriendBadgePainter oldDelegate) =>
      oldDelegate.color != color;
}

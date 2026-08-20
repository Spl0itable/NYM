import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'ghost_mode.dart';

/// Ghost Mode toggle for the mesh status bar: a ghost glyph badged with a red
/// cross when off and a green check when on. Enabling asks first, because it
/// deliberately breaks the link between this device and the user's npub.
class GhostModeButton extends ConsumerWidget {
  const GhostModeButton({super.key, required this.colors});

  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(ghostModeProvider.select((s) => s.enabled));
    return Tooltip(
      message: on ? tr('Ghost Mode on') : tr('Ghost Mode off'),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _toggle(context, ref, on),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CustomPaint(
              painter: _GhostPainter(
                body: on ? colors.primary : colors.textDim,
                badge: on ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                surface: colors.bgSecondary,
                checked: on,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    final ghost = ref.read(ghostModeProvider.notifier);
    if (on) {
      await ghost.disable();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.bgSecondary,
        title: Text(tr('Enable Ghost Mode?'),
            style: TextStyle(color: colors.text, fontSize: 16)),
        content: Text(
          tr('Ghost Mode hides who you are on the Bluetooth mesh.\n\n'
              'Your device stops advertising your nym and your Nostr identity. '
              'It presents a throwaway name and key instead, and replaces them '
              'every few minutes, so nearby devices cannot recognise you or '
              'follow you between places.\n\n'
              'You can still send and receive messages. Anyone you talk to '
              'while it is on sees an anonymous identity, not your usual one, '
              'and will not be able to tell it was you. Turning it off restores '
              'your normal identity.'),
          style: TextStyle(color: colors.textDim, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel'), style: TextStyle(color: colors.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('OK'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
    if (ok == true) await ghost.enable();
  }
}

class _GhostPainter extends CustomPainter {
  _GhostPainter({
    required this.body,
    required this.badge,
    required this.surface,
    required this.checked,
  });

  final Color body;
  final Color badge;

  /// Painted as a ring behind the badge so it stays readable when the badge and
  /// the ghost body land on similar colours (green check on a green ghost).
  final Color surface;
  final bool checked;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Off reads as an empty outline, on as a solid shape — legible at 24px
    // without relying on the badge colour alone.
    final stroke = w * 0.09;
    final p = Paint()
      ..color = body
      ..style = checked ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round;

    // Ghost: domed head, straight sides, scalloped hem.
    final path = Path()
      ..moveTo(w * 0.10, h * 0.92)
      ..lineTo(w * 0.10, h * 0.44)
      ..arcToPoint(Offset(w * 0.74, h * 0.44),
          radius: Radius.circular(w * 0.32))
      ..lineTo(w * 0.74, h * 0.92)
      ..lineTo(w * 0.63, h * 0.80)
      ..lineTo(w * 0.53, h * 0.92)
      ..lineTo(w * 0.42, h * 0.80)
      ..lineTo(w * 0.31, h * 0.92)
      ..lineTo(w * 0.21, h * 0.80)
      ..close();
    if (checked) {
      // Filled: punch the eyes back out of the solid body.
      final eye = Paint()..blendMode = BlendMode.clear;
      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawPath(path, p);
      canvas.drawCircle(Offset(w * 0.30, h * 0.47), w * 0.065, eye);
      canvas.drawCircle(Offset(w * 0.54, h * 0.47), w * 0.065, eye);
      canvas.restore();
    } else {
      // Outline: the body is a stroke, so the eyes are drawn as solid dots.
      canvas.drawPath(path, p);
      final eye = Paint()
        ..color = body
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(w * 0.30, h * 0.47), w * 0.055, eye);
      canvas.drawCircle(Offset(w * 0.54, h * 0.47), w * 0.055, eye);
    }

    // Status badge, bottom-right. Inset so the ring stays inside the box.
    final c = Offset(w * 0.72, h * 0.72);
    final r = w * 0.20;
    canvas.drawCircle(c, r * 1.30, Paint()..color = surface);
    canvas.drawCircle(c, r, Paint()..color = badge);
    final mark = Paint()
      ..color = Colors.white
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (checked) {
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - r * 0.45, c.dy)
          ..lineTo(c.dx - r * 0.08, c.dy + r * 0.38)
          ..lineTo(c.dx + r * 0.48, c.dy - r * 0.40),
        mark,
      );
    } else {
      canvas.drawLine(c.translate(-r * 0.38, -r * 0.38),
          c.translate(r * 0.38, r * 0.38), mark);
      canvas.drawLine(c.translate(r * 0.38, -r * 0.38),
          c.translate(-r * 0.38, r * 0.38), mark);
    }
  }

  @override
  bool shouldRepaint(_GhostPainter old) =>
      old.body != body ||
      old.badge != badge ||
      old.surface != surface ||
      old.checked != checked;
}

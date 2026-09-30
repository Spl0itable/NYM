import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../anchored_popup.dart';

/// Verification state of a sealed (NIP-17/NIP-59) message's sender, as in the PWA's `senderVerified`.
enum CryptoVerifyState { verified, unverified, unknown }

/// The padlock badge next to a PM/group message timestamp; tapping opens the verification popup.
class CryptoVerifiedBadge extends StatelessWidget {
  const CryptoVerifiedBadge({super.key, required this.state, this.size = 12});

  final CryptoVerifyState state;
  final double size;

  Color get _color {
    switch (state) {
      case CryptoVerifyState.verified:
        return const Color(0xFF2ECC71);
      case CryptoVerifyState.unverified:
        return const Color(0xFFE74C3C);
      case CryptoVerifyState.unknown:
        return const Color(0xFF9AA0A6);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Margin outside the box so the popup anchors on the lock itself.
      padding: const EdgeInsets.only(left: 4),
      child: Builder(
        builder: (anchorContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showVerificationPopup(anchorContext, state),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _LockPainter(state, _color)),
          ),
        ),
      ),
    );
  }
}

class _LockPainter extends CustomPainter {
  _LockPainter(this.state, this.color);

  final CryptoVerifyState state;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 11, 18, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    final shackle = Path()
      ..moveTo(7, 11)
      ..lineTo(7, 7)
      ..arcToPoint(const Offset(17, 7),
          radius: const Radius.circular(5), clockwise: true)
      ..lineTo(17, 11);
    canvas.drawPath(shackle, paint);

    final glyph = Path();
    switch (state) {
      case CryptoVerifyState.verified:
        glyph
          ..moveTo(8.5, 16.5)
          ..lineTo(11, 19)
          ..lineTo(15.5, 14.5);
        break;
      case CryptoVerifyState.unverified:
        glyph
          ..moveTo(9.5, 14)
          ..lineTo(14.5, 19)
          ..moveTo(14.5, 14)
          ..lineTo(9.5, 19);
        break;
      case CryptoVerifyState.unknown:
        glyph
          ..moveTo(9.6, 14.6)
          ..arcToPoint(const Offset(13.2, 16.6),
              radius: const Radius.circular(2.4), clockwise: true)
          ..cubicTo(13.2, 17.6, 12, 18, 12, 19)
          ..moveTo(12, 21.2)
          ..lineTo(12, 21.21);
        break;
    }
    canvas.drawPath(glyph, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LockPainter old) =>
      old.state != state || old.color != color;
}

/// Opens the verification-info popup anchored to the tapped lock.
void showVerificationPopup(BuildContext context, CryptoVerifyState state) {
  final (title, titleColor, body) = switch (state) {
    CryptoVerifyState.verified => (
        tr('Cryptographically verified'),
        const Color(0xFF2ECC71),
        tr("The seal wrapping this message (NIP-17 / NIP-59 kind 13) was signed by "
            "the sender's long-term identity key, and that signer matches the "
            "author the message claims. The displayed identity is "
            "cryptographically authenticated and cannot be forged by a relay or "
            "third party."),
      ),
    CryptoVerifyState.unknown => (
        tr('Verification unknown'),
        const Color(0xFF9AA0A6),
        tr("This message's sender could not be cryptographically verified on this "
            "device — its verification seal isn't available (for example, it was "
            "restored from saved history). The displayed identity is unconfirmed: "
            "don't assume it is authenticated."),
      ),
    CryptoVerifyState.unverified => (
        tr('Unverified sender'),
        const Color(0xFFE74C3C),
        tr("This message uses a Bitchat-format seal signed with a throwaway, "
            "per-message key that has no binding to any long-term identity. The "
            "displayed sender is an unverified, self-asserted claim — treat the "
            "identity with caution, as it could be spoofed."),
      ),
  };

  showAnchoredInfoPopup(context, title: title, titleColor: titleColor, body: body);
}

/// Info card anchored to a tapped badge, shared by the lock and the PQ shield; no scrim, closes on outside tap.
void showAnchoredInfoPopup(
  BuildContext context, {
  required String title,
  required Color titleColor,
  required String body,
}) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final overlay = Overlay.of(context, rootOverlay: true);
  final screen = MediaQuery.of(context).size;

  final double width = screen.width - 16 < 280 ? screen.width - 16 : 280;

  OverlayEntry? entry;
  void close() {
    if (entry?.mounted ?? false) entry!.remove();
    entry = null;
  }

  entry = OverlayEntry(
    builder: (ctx) {
      final c = ctx.nym;
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              onPanStart: (_) => close(),
            ),
          ),
          AnchoredPopup(
            anchor: rect,
            margin: 8,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: BoxConstraints(minWidth: 160, maxWidth: width),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  borderRadius: NymRadius.rmd,
                  border: Border.all(
                    color: c.isLight
                        ? Colors.black.withValues(alpha: 0.08)
                        : c.glassBorder,
                  ),
                  boxShadow: c.isLight
                      ? const [
                          BoxShadow(
                              color: Color(0x1F000000),
                              offset: Offset(0, 8),
                              blurRadius: 32),
                        ]
                      : [
                          const BoxShadow(
                              color: Color(0x80000000),
                              offset: Offset(0, 8),
                              blurRadius: 32),
                          BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                          const BoxShadow(
                              color: Color(0x0DFFFFFF), spreadRadius: 1),
                        ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Opacity(
                      opacity: 0.85,
                      child: Text(
                        body,
                        style: TextStyle(
                          color: c.text,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  overlay.insert(entry!);
}

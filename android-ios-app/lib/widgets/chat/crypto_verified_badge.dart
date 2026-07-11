import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';

/// Cryptographic-verification state of a sealed (NIP-17/NIP-59) message,
/// mirroring the PWA's tri-state `senderVerified` (`messages.js:732-757`):
///
/// * [verified] — the seal was signed by the sender's long-term identity key
///   and that signer matches the claimed author (green lock + check).
/// * [unverified] — a Bitchat-format seal signed with a throwaway per-message
///   key with no identity binding (red lock + ✗).
/// * [unknown] — the seal isn't available on this device (e.g. restored from
///   history), so verification can't be performed (grey lock + ?).
enum CryptoVerifyState { verified, unverified, unknown }

/// The `.crypto-verified-badge` lock shown next to a PM/group message's
/// timestamp (`messages.js:758` `mkLock`, `styles-components.css:1421`). A 12×12
/// stroked padlock whose interior glyph + colour encode the [state]; tapping it
/// opens the verification-info popup (`showVerificationPopup`,
/// `messages.js:3405`).
class CryptoVerifiedBadge extends StatelessWidget {
  const CryptoVerifiedBadge({super.key, required this.state, this.size = 12});

  final CryptoVerifyState state;
  final double size;

  /// Lock colour per state (`.crypto-verified-badge` / `.unverified` /
  /// `.unknown`): verified `#2ecc71`, unverified `#e74c3c`, unknown `#9aa0a6`.
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
      // `.crypto-verified-badge { margin-left: 4px }` — a margin sits OUTSIDE
      // the element's box, so the popup anchors on the lock itself (the inner
      // Builder context), not the padded footprint.
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

/// Strokes the padlock + state glyph from the PWA's inline SVG path data, in the
/// 24-unit viewBox the SVG uses, scaled to the widget size. `stroke-width:2`,
/// round caps/joins, no fill (`messages.js:746-756`).
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

    // Lock body: <rect x=3 y=11 w=18 h=11 rx=2 ry=2>.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 11, 18, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    // Shackle: M7 11V7 a5 5 0 0 1 10 0 v4.
    final shackle = Path()
      ..moveTo(7, 11)
      ..lineTo(7, 7)
      ..arcToPoint(const Offset(17, 7),
          radius: const Radius.circular(5), clockwise: true)
      ..lineTo(17, 11);
    canvas.drawPath(shackle, paint);

    // Interior glyph per state.
    final glyph = Path();
    switch (state) {
      case CryptoVerifyState.verified:
        // M8.5 16.5 l2.5 2.5 4.5-4.5  (check)
        glyph
          ..moveTo(8.5, 16.5)
          ..lineTo(11, 19)
          ..lineTo(15.5, 14.5);
        break;
      case CryptoVerifyState.unverified:
        // M9.5 14 l5 5  /  M14.5 14 l-5 5  (✗)
        glyph
          ..moveTo(9.5, 14)
          ..lineTo(14.5, 19)
          ..moveTo(14.5, 14)
          ..lineTo(9.5, 19);
        break;
      case CryptoVerifyState.unknown:
        // M9.6 14.6 a2.4 2.4 0 0 1 3.6 2 c0 1 -1.2 1.4 -1.2 2.4  +  dot
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

/// Opens the verification-info popup (`showVerificationPopup`,
/// `messages.js:3405-3424`): a `.reactors-modal`-chromed `.verification-popup`
/// card (styles-chat.css:505-529) ANCHORED to the tapped lock — the same
/// placement engine as the timestamp popup, with NO dimming scrim. Vertical:
/// 6px above the anchor when there's head-room (`rect.top > approxHeight(170)
/// + 20`), else 6px below. Horizontal: `left = max(8, min(rect.left,
/// innerWidth - width - 8))`. Dismissed on the next outside tap / drag
/// (mirrors the PWA's document-click + scroll close).
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

  // Anchor on the tapped lock's global bounds (the PWA's
  // `anchorEl.getBoundingClientRect()`).
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final overlay = Overlay.of(context, rootOverlay: true);
  final screen = MediaQuery.of(context).size;

  // `const approxHeight = 170` — prefer above when there's head-room.
  final above = rect.top > 170 + 20;
  // `left = Math.max(8, Math.min(rect.left, innerWidth - width - 8))` with the
  // popup's `.verification-popup` max-width of 280 (shrunk on tiny screens so
  // the 8px viewport gutters hold).
  final double width = screen.width - 16 < 280 ? screen.width - 16 : 280;
  double left = rect.left;
  if (left > screen.width - width - 8) left = screen.width - width - 8;
  if (left < 8) left = 8;

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
          // No dimming scrim — just an outside-tap / scroll-start dismiss
          // barrier (PWA closes on document click + scroll).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              onPanStart: (_) => close(),
            ),
          ),
          Positioned(
            left: left,
            top: above ? null : rect.bottom + 6,
            bottom: above ? screen.height - rect.top + 6 : null,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                // `.reactors-modal { min-width: 160 }` +
                // `.verification-popup { max-width: 280 }`.
                constraints: BoxConstraints(minWidth: 160, maxWidth: width),
                // `.verification-popup { padding: 12px 14px }`.
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  borderRadius: NymRadius.rmd,
                  border: Border.all(
                    color: c.isLight
                        ? Colors.black.withValues(alpha: 0.08)
                        : c.glassBorder,
                  ),
                  // dark: shadow-lg + shadow-glow + a 1px white@0.05 ring;
                  // light: `0 8px 32px rgba(0,0,0,0.12)`.
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
                    // `.verification-popup-title`: 13px w700, state colour.
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    // `.verification-popup { gap: 6px }`.
                    const SizedBox(height: 6),
                    // `.verification-popup-body`: 12px/1.45 @ opacity 0.85.
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

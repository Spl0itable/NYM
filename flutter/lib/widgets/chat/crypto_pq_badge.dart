import 'package:flutter/material.dart';

import '../../features/i18n/i18n.dart';
import 'crypto_verified_badge.dart' show showAnchoredInfoPopup;

/// Post-quantum coverage of a message, kept separate from [CryptoVerifyState] (confidentiality vs authentication).
enum PqBadgeState {
  /// Every copy used hybrid ECDH + ML-KEM-768 with ML-KEM keys seeded from identity roots on both sides.
  full,

  /// Hybrid, but an ML-KEM key was derived from a Nostr identity key, so recovering that key breaks it.
  legacy,

  /// Group message where only some members got a post-quantum copy; one classical copy exposes the plaintext.
  partial,

  /// No post-quantum layer; shown explicitly because a missing shield would be ambiguous.
  classical,
}

/// Shield state for an encrypted message; [pqCoverage] overrides [pqEncrypted] and [pqRoot] caps at legacy.
PqBadgeState pqBadgeStateFor({
  required bool pqEncrypted,
  bool pqRoot = false,
  ({int pq, int total})? pqCoverage,
  bool isGroup = false,
}) {
  final cov = pqCoverage;
  if (cov != null && cov.total > 0) {
    if (cov.pq == 0) return PqBadgeState.classical;
    if (cov.pq != cov.total) return PqBadgeState.partial;
    return pqRoot ? PqBadgeState.full : PqBadgeState.legacy;
  }
  // A group message without a coverage count is only partly protected: the same plaintext went to every member.
  if (pqEncrypted) {
    if (isGroup) return PqBadgeState.partial;
    return pqRoot ? PqBadgeState.full : PqBadgeState.legacy;
  }
  return PqBadgeState.classical;
}

/// The `.crypto-pq-badge` shield shown next to the verification lock.
class CryptoPqBadge extends StatelessWidget {
  const CryptoPqBadge({
    super.key,
    required this.state,
    this.coverage,
    this.size = 12,
  });

  final PqBadgeState state;

  final ({int pq, int total})? coverage;

  final double size;

  /// Only full coverage is violet; the others are neutral gray, not error red, since neither is a failure.
  Color get _color => switch (state) {
        PqBadgeState.full => const Color(0xFF8B7CF6),
        PqBadgeState.partial => const Color(0xFF9AA0A6),
        PqBadgeState.legacy => const Color(0xFF9AA0A6),
        PqBadgeState.classical => const Color(0xFF9AA0A6).withValues(alpha: 0.65),
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Margin outside the box so the popup anchors on the shield itself.
      padding: const EdgeInsets.only(left: 3),
      child: Builder(
        builder: (anchorContext) => Semantics(
          button: true,
          label: switch (state) {
            PqBadgeState.full => tr(kPqFullTitle),
            PqBadgeState.partial => tr(kPqPartialTitle),
            PqBadgeState.legacy => tr(kPqLegacyTitle),
            PqBadgeState.classical => tr(kPqClassicalTitle),
          },
          onTap: () => showPqPopup(anchorContext, state, coverage: coverage),
          excludeSemantics: true,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showPqPopup(anchorContext, state, coverage: coverage),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _ShieldPainter(state, _color)),
          ),
        ),
        ),
      ),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  _ShieldPainter(this.state, this.color);

  final PqBadgeState state;
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

    final shield = Path()
      ..moveTo(12, 2.5)
      ..lineTo(20, 5.5)
      ..lineTo(20, 11.5)
      ..cubicTo(20, 16, 16.6, 19.1, 12, 21)
      ..cubicTo(7.4, 19.1, 4, 16, 4, 11.5)
      ..lineTo(4, 5.5)
      ..close();

    final orbitRect = Rect.fromCenter(
        center: const Offset(12, 12), width: 12.4, height: 5.2);
    final orbit = Path()..addOval(orbitRect);
    // Built from matrix constructors: the mutating translate/scale helpers are deprecated on newer SDKs.
    const rotateAbout = 12.0;
    final rotated = orbit.transform((Matrix4.translationValues(
                rotateAbout, rotateAbout, 0.0) *
            Matrix4.rotationZ(-32 * 3.1415926535897932 / 180) *
            Matrix4.translationValues(-rotateAbout, -rotateAbout, 0.0))
        .storage);

    if (state == PqBadgeState.partial || state == PqBadgeState.legacy) {
      _strokeDashed(canvas, shield, paint);
      _strokeDashed(canvas, rotated, paint);
    } else if (state == PqBadgeState.classical) {
      // Legacy draws the shield struck through and without the orbit, which denotes post-quantum.
      canvas.drawPath(shield, paint);
      canvas.drawLine(const Offset(5.5, 5), const Offset(18.5, 18), paint);
    } else {
      canvas.drawPath(shield, paint);
      canvas.drawPath(rotated, paint);
    }
    canvas.restore();
  }

  void _strokeDashed(Canvas canvas, Path path, Paint paint) {
    const dash = 3.0, gap = 2.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ShieldPainter old) =>
      old.state != state || old.color != color;
}

/// Post-quantum popup copy; each string is named so `kPqPopupStrings` can be checked against the i18n catalog.
const String kPqFullTitle = 'Quantum-resistant encryption';
const String kPqFullBody =
    "This message's key exchange combined the standard NIP-44 secp256k1 "
    "ECDH with ML-KEM-768, a post-quantum key encapsulation mechanism. "
    "Both must be broken to recover the message, so it stays "
    "confidential against an adversary recording traffic today to "
    "decrypt with a future quantum computer. The sender's signature is "
    "still secp256k1 — this protects confidentiality, not "
    "authentication.";
const String kPqPartialTitle = 'Partly quantum-resistant';
const String kPqPartialLead = 'This message was quantum-resistant to ';
const String kPqPartialCount = '%d of %d members';
const String kPqPartialSome = 'some members';
const String kPqLegacyTitle = 'Quantum-resistant, legacy key';
const String kPqLegacyBody =
    "The hybrid exchange ran, but one side's ML-KEM key came from its Nostr "
    "identity key rather than from a recovery code. A quantum computer that "
    "recovers the identity key recovers this one with it. New messages "
    "upgrade automatically once both sides hold a code.";
const String kPqClassicalTitle = 'Not quantum-resistant';
const String kPqClassicalBody =
    'This message is end-to-end encrypted with the standard NIP-44 secp256k1 '
    'key exchange, and nobody but the participants can read it today. It has '
    'no post-quantum layer, so an adversary recording it now could decrypt it '
    'with a future quantum computer. Messages sent before either side '
    'upgraded stay this way permanently — the ciphertext already exists and '
    'cannot be re-sealed. New messages go quantum-resistant automatically '
    'once both sides have published a post-quantum key.';
const String kPqPartialTail =
    ". The rest haven't published a post-quantum key, so their "
    "copies used standard NIP-44 encryption only — and because "
    "those copies carry the same message, treat this one as "
    "classically encrypted overall.";

const List<String> kPqPopupStrings = [
  kPqFullTitle,
  kPqFullBody,
  kPqPartialTitle,
  kPqPartialLead,
  kPqPartialCount,
  kPqPartialSome,
  kPqPartialTail,
  kPqLegacyTitle,
  kPqLegacyBody,
  kPqClassicalTitle,
  kPqClassicalBody,
];

void showPqPopup(
  BuildContext context,
  PqBadgeState state, {
  ({int pq, int total})? coverage,
}) {
  final (title, titleColor, body) = switch (state) {
    PqBadgeState.full => (
        tr(kPqFullTitle),
        const Color(0xFF8B7CF6),
        tr(kPqFullBody),
      ),
    PqBadgeState.partial => (
        tr(kPqPartialTitle),
        const Color(0xFF9AA0A6),
        tr(kPqPartialLead) +
            (coverage != null
                ? tr(kPqPartialCount)
                    .replaceFirst('%d', '${coverage.pq}')
                    .replaceFirst('%d', '${coverage.total}')
                : tr(kPqPartialSome)) +
            tr(kPqPartialTail),
      ),
    PqBadgeState.legacy => (
        tr(kPqLegacyTitle),
        const Color(0xFF9AA0A6),
        tr(kPqLegacyBody),
      ),
    PqBadgeState.classical => (
        tr(kPqClassicalTitle),
        const Color(0xFF9AA0A6),
        tr(kPqClassicalBody),
      ),
  };

  showAnchoredInfoPopup(context,
      title: title, titleColor: titleColor, body: body);
}

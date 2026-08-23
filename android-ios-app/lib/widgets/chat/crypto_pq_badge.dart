import 'package:flutter/material.dart';

import '../../features/i18n/i18n.dart';
import 'crypto_verified_badge.dart' show showAnchoredInfoPopup;

/// Post-quantum coverage of a message.
///
/// Deliberately SEPARATE from [CryptoVerifyState]: that lock encodes
/// authentication (who signed this), this shield encodes confidentiality (how
/// hard the key exchange is to break). The two are orthogonal — a message can
/// be post-quantum encrypted yet unverified, or verified yet classically
/// encrypted — so collapsing them into one glyph would say something false
/// about one axis or the other.
enum PqBadgeState {
  /// Every copy of this message used the hybrid ECDH + ML-KEM-768 exchange.
  full,

  /// A group message where only some members could receive a post-quantum
  /// copy. Rendered distinctly rather than as protected: if even one member got
  /// a classical copy of the same plaintext, breaking secp256k1 reveals the
  /// message.
  partial,

  /// Encrypted, but with no post-quantum layer at all.
  ///
  /// Shown rather than omitted because NO badge is ambiguous: a missing shield
  /// could equally mean the message is not quantum-resistant, that the
  /// indicator is broken, or that this build lacks the feature, and the reader
  /// cannot tell which. Saying so plainly is the point of a security
  /// indicator, and it is what makes the shield's absence meaningful when it
  /// does appear.
  classical,
}

/// Resolves the shield state for a message.
///
/// Never null for an encrypted message: one of the three states always
/// applies. Callers decide whether the message is encrypted at all — a public
/// channel message is plaintext on the relay, and a shield of any kind there
/// would imply an encryption it does not have (see `_pqState` in
/// message_row.dart).
///
/// [pqCoverage] is the group fan-out's (post-quantum, total) member counts;
/// when present it OVERRIDES [pqEncrypted], because an optimistic per-message
/// flag must never outrank what actually went on the wire.
PqBadgeState pqBadgeStateFor({
  required bool pqEncrypted,
  ({int pq, int total})? pqCoverage,
}) {
  final cov = pqCoverage;
  if (cov != null && cov.total > 0) {
    if (cov.pq == 0) return PqBadgeState.classical;
    return cov.pq == cov.total ? PqBadgeState.full : PqBadgeState.partial;
  }
  return pqEncrypted ? PqBadgeState.full : PqBadgeState.classical;
}

/// The `.crypto-pq-badge` shield shown next to the verification lock.
///
/// A shield silhouette is what reads at 12px — interior detail would not — and
/// the single tilted orbit inside distinguishes it from the plain ✓
/// `verified-badge` without using a letterform, which would not survive
/// translation. Violet, so it can never be confused with the lock's green /
/// red / grey.
class CryptoPqBadge extends StatelessWidget {
  const CryptoPqBadge({
    super.key,
    required this.state,
    this.coverage,
    this.size = 12,
  });

  final PqBadgeState state;

  /// (post-quantum, total) member counts, so the popup can name them.
  final ({int pq, int total})? coverage;

  final double size;

  /// `#8B7CF6` for full coverage; the other two drop to a neutral grey — and
  /// deliberately not the lock's error red. Partial is a weaker guarantee and
  /// classical is the encryption everyone had until recently; neither is a
  /// failure. Classical is dimmed further so the three read as one scale.
  Color get _color => switch (state) {
        PqBadgeState.full => const Color(0xFF8B7CF6),
        PqBadgeState.partial => const Color(0xFF9AA0A6),
        PqBadgeState.classical => const Color(0xFF9AA0A6).withValues(alpha: 0.65),
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      // `.crypto-pq-badge { margin-left: 3px }` — outside the box, so the popup
      // anchors on the shield itself.
      padding: const EdgeInsets.only(left: 3),
      child: Builder(
        builder: (anchorContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showPqPopup(anchorContext, state, coverage: coverage),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _ShieldPainter(state, _color)),
          ),
        ),
      ),
    );
  }
}

/// Strokes the shield + orbit from the PWA's inline SVG path data, in the same
/// 24-unit viewBox, scaled to the widget size.
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

    // M12 2.5 L20 5.5 v6 c0 4.5-3.4 7.6-8 9.5 -4.6-1.9-8-5-8-9.5 v-6 z
    final shield = Path()
      ..moveTo(12, 2.5)
      ..lineTo(20, 5.5)
      ..lineTo(20, 11.5)
      ..cubicTo(20, 16, 16.6, 19.1, 12, 21)
      ..cubicTo(7.4, 19.1, 4, 16, 4, 11.5)
      ..lineTo(4, 5.5)
      ..close();

    // <ellipse cx=12 cy=12 rx=6.2 ry=2.6 transform="rotate(-32 12 12)">
    final orbitRect = Rect.fromCenter(
        center: const Offset(12, 12), width: 12.4, height: 5.2);
    final orbit = Path()..addOval(orbitRect);
    // Composed by multiplication rather than the mutating helpers: the
    // translate/scale ones are deprecated on current SDKs and their
    // replacements do not exist on the oldest this package supports
    // (pubspec: sdk ^3.6.0), so either spelling breaks one end of the range.
    // These constructors are stable across all of it.
    const rotateAbout = 12.0;
    final rotated = orbit.transform((Matrix4.translationValues(
                rotateAbout, rotateAbout, 0.0) *
            Matrix4.rotationZ(-32 * 3.1415926535897932 / 180) *
            Matrix4.translationValues(-rotateAbout, -rotateAbout, 0.0))
        .storage);

    if (state == PqBadgeState.partial) {
      // `stroke-dasharray: 3 2` — reads as "not fully closed" at a glance.
      _strokeDashed(canvas, shield, paint);
      _strokeDashed(canvas, rotated, paint);
    } else if (state == PqBadgeState.classical) {
      // Same silhouette, so the three states read as one scale rather than
      // three unrelated icons — but struck through, and WITHOUT the orbit:
      // the orbit is the post-quantum part, so drawing one here would be the
      // one thing this badge exists to deny.
      canvas.drawPath(shield, paint);
      canvas.drawLine(const Offset(5.5, 5), const Offset(18.5, 18), paint);
    } else {
      canvas.drawPath(shield, paint);
      canvas.drawPath(rotated, paint);
    }
    canvas.restore();
  }

  /// Dart has no stroke-dasharray, so walk the path metrics and stroke 3-unit
  /// dashes separated by 2-unit gaps.
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

/// The post-quantum info popup, reached by tapping the shield.
///
/// The copy names the actual primitives and states the limit plainly: this
/// protects confidentiality, not authentication. Signatures are still
/// secp256k1, so an adversary who already had a quantum computer could forge
/// one and MITM in real time. What the hybrid key exchange defeats is
/// harvest-now-decrypt-later, which is the threat that actually exists today —
/// and overstating it in the UI would be worse than saying nothing.
/// The popup's copy, named so `kPqPopupStrings` can be checked against the
/// background-sweep catalog — a string the catalog doesn't carry never gets
/// translated, and a wording change that silently drops out of it is invisible
/// until someone reads the popup in another language.
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

/// Every literal the popup can show.
const List<String> kPqPopupStrings = [
  kPqFullTitle,
  kPqFullBody,
  kPqPartialTitle,
  kPqPartialLead,
  kPqPartialCount,
  kPqPartialSome,
  kPqPartialTail,
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
    PqBadgeState.classical => (
        tr(kPqClassicalTitle),
        const Color(0xFF9AA0A6),
        tr(kPqClassicalBody),
      ),
  };

  showAnchoredInfoPopup(context,
      title: title, titleColor: titleColor, body: body);
}

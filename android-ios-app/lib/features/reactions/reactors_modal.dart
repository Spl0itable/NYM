import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/common/nym_avatar.dart';

/// One reactor row in the reactor-list popup.
class ReactorEntry {
  const ReactorEntry({
    required this.pubkey,
    required this.nym,
    this.suffix = '',
    this.isYou = false,
  });

  /// Reactor pubkey (used for the avatar seed + opening their context menu).
  final String pubkey;

  /// Base nym (without the `#suffix`).
  final String nym;

  /// 4-hex pubkey suffix shown dimmed after the nym.
  final String suffix;

  /// Whether this reactor is the local user.
  final bool isYou;
}

/// The reactor-list popup (reactions.js `showReactorsModal`,
/// styles-features.css `.reactors-modal`). Anchored above a badge, it lists who
/// reacted with [emoji], capped at 50 rows with a "+N more" overflow line, and
/// lets a row tap open that user's context menu via [onTapReactor].
///
/// Presented as an [OverlayEntry] by [showReactorsModal] so it can be anchored
/// to the tapped badge and dismissed on outside-tap (matching the PWA's
/// document-level close + scroll-dismiss behaviour).
class ReactorsModal extends StatelessWidget {
  const ReactorsModal({
    super.key,
    required this.emoji,
    required this.reactors,
    this.onTapReactor,
  });

  static const int maxRows = 50;

  final String emoji;
  final List<ReactorEntry> reactors;
  final void Function(ReactorEntry)? onTapReactor;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final shown = reactors.take(maxRows).toList();
    final overflow = reactors.length - shown.length;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: 160,
          maxWidth: 240,
          maxHeight: 260,
        ),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `.reactors-modal-header`: 40px emoji + count.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 40, height: 1)),
                  const SizedBox(width: 6),
                  Text(
                    '${reactors.length}',
                    style: TextStyle(fontSize: 12, color: c.textDim),
                  ),
                ],
              ),
            ),
            // `.reactors-modal-list`.
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (final r in shown) _row(context, r),
                  if (overflow > 0)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Text(
                        '+$overflow more',
                        style: TextStyle(
                          fontSize: 12,
                          color: c.textDim,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ReactorEntry r) {
    final c = context.nym;
    return InkWell(
      onTap: onTapReactor == null ? null : () => onTapReactor!(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            NymAvatar(seed: r.pubkey, size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(fontSize: 13, color: c.text),
                  children: [
                    TextSpan(text: r.nym),
                    TextSpan(
                      text: '#${r.suffix}',
                      style: TextStyle(
                        color: c.text.withValues(alpha: 0.5),
                        fontSize: 13 * 0.9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (r.isYou) ...[
              const SizedBox(width: 6),
              Text(
                'you',
                style: TextStyle(
                  fontSize: 10,
                  color: c.primary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows [ReactorsModal] anchored just above [anchorRect] (the badge bounds in
/// global coordinates), clamped to the viewport, dismissed on outside tap.
void showReactorsModal(
  BuildContext context, {
  required Rect anchorRect,
  required String emoji,
  required List<ReactorEntry> reactors,
  void Function(ReactorEntry)? onTapReactor,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final size = MediaQuery.of(context).size;
  const modalW = 240.0;
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
  }

  // Horizontal: align left edge with badge, clamp to viewport.
  double left = anchorRect.left;
  if (left + modalW > size.width - 10) left = size.width - modalW - 10;
  if (left < 10) left = 10;

  // Vertical: prefer above the badge, fall back to below.
  final spaceAbove = anchorRect.top;
  final preferAbove = spaceAbove > 270;

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        // Outside-tap scrim.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          left: left,
          top: preferAbove ? null : anchorRect.bottom + 6,
          bottom: preferAbove ? (size.height - anchorRect.top + 6) : null,
          child: ReactorsModal(
            emoji: emoji,
            reactors: reactors,
            onTapReactor: onTapReactor == null
                ? null
                : (r) {
                    close();
                    onTapReactor(r);
                  },
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
}

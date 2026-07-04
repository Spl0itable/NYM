import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../messages/format/message_content.dart';

/// One reactor row in the reactor-list popup.
class ReactorEntry {
  const ReactorEntry({
    required this.pubkey,
    required this.nym,
    this.suffix = '',
    this.isYou = false,
    this.imageUrl,
    this.subtitle,
  });

  /// Reactor pubkey (used for the avatar seed + opening their context menu).
  final String pubkey;

  /// Base nym (without the `#suffix`).
  final String nym;

  /// 4-hex pubkey suffix shown dimmed after the nym.
  final String suffix;

  /// Whether this reactor is the local user.
  final bool isYou;

  /// The reactor's profile picture (kind-0 `picture`); identicon fallback when
  /// null (Rule 4 — every NymAvatar receives an imageUrl).
  final String? imageUrl;

  /// Optional secondary line under the nym (e.g. a poll voter's chosen option).
  final String? subtitle;
}

/// The reactor-list popup (reactions.js `showReactorsModal`,
/// styles-features.css `.reactors-modal`). Anchored above a badge, it lists who
/// reacted with [emoji], capped at 50 rows with a "+N more" overflow line, and
/// lets a row tap open that user's context menu via [onTapReactor].
///
/// Presented as an [OverlayEntry] by [showReactorsModal] so it can be anchored
/// to the tapped badge and dismissed on outside-tap (matching the PWA's
/// document-level close + scroll-dismiss behaviour).
class ReactorsModal extends ConsumerWidget {
  const ReactorsModal({
    super.key,
    required this.emoji,
    required this.reactors,
    this.onTapReactor,
    this.title,
  });

  static const int maxRows = 50;

  final String emoji;
  final List<ReactorEntry> reactors;
  final void Function(ReactorEntry)? onTapReactor;

  /// Optional header title shown in place of the 40px emoji + count (Foundations
  /// reuses this list for a "Seen by" sheet). When null the emoji+count header
  /// is rendered (the reactions case).
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final shown = reactors.take(maxRows).toList();
    final overflow = reactors.length - shown.length;
    // Watch the unified user store so an avatar that lands AFTER this sheet opens
    // — whether from the D1 `profile-get` that `ensureProfiles` kicked off, or a
    // live relay kind-0 — fills the row in immediately. Both sources ingest into
    // `usersProvider`, so this one watch covers either path; the entry's baked-in
    // [ReactorEntry.imageUrl] is the fallback until then.
    final users = ref.watch(usersProvider);

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
          // dark (styles-chat.css:495): shadow-lg + shadow-glow + a 1px
          // white@0.05 ring; light (styles-themes-responsive.css:1196-1199):
          // `0 8px 32px rgba(0,0,0,0.12)` only.
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `.reactors-modal-header`: 40px emoji + count, or a [title] label.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: title != null
                  ? Text(
                      title!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                    )
                  : Row(
                      children: [
                        // `renderReactionEmoji` (emoji.js:342-351): only an
                        // exact `:shortcode:` reaction renders as its custom-
                        // emoji image, at `.custom-emoji-reaction` 1.45em of
                        // the 40px `.reactors-modal-emoji` font (= 58px,
                        // margin 0); unicode stays text.
                        InlineEmojiText(
                          text: emoji,
                          style: const TextStyle(fontSize: 40, height: 1),
                          wholeStringOnly: true,
                          emojiSize: 40 * 1.45,
                          emojiMargin: EdgeInsets.zero,
                          // `.reactors-modal-emoji` is `inline-flex;
                          // align-items: center` (styles-chat.css:540-545), so
                          // the img is flex-centered — `vertical-align` inert.
                          emojiAlignment: PlaceholderAlignment.middle,
                        ),
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
                  for (final r in shown)
                    _row(context, r,
                        users[r.pubkey]?.profile?.picture ?? r.imageUrl),
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

  Widget _row(BuildContext context, ReactorEntry r, String? imageUrl) {
    final c = context.nym;
    return InkWell(
      onTap: onTapReactor == null ? null : () => onTapReactor!(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            NymAvatar(seed: r.pubkey, size: 22, imageUrl: imageUrl),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  RichText(
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
                  // Secondary line — e.g. a poll voter's chosen option.
                  if (r.subtitle != null && r.subtitle!.isNotEmpty)
                    Text(
                      r.subtitle!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.textDim),
                    ),
                ],
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
  String? title,
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
            title: title,
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

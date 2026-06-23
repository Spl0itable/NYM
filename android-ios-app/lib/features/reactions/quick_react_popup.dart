import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// The six default quick-react emojis (calls.js `_messageQuickReactDefaults`,
/// line 1491: `['👍', '❤️', '😂', '🔥', '👎', '😮']`). The PWA pads the user's
/// recent reactions up to six with these and drops duplicates.
const List<String> kQuickReactDefaults = ['👍', '❤️', '😂', '🔥', '👎', '😮'];

/// Builds the six-emoji quick-react row: recents first, padded with the
/// defaults, deduped, capped at six (mirrors calls.js lines 1488-1499).
List<String> quickReactEmojis(List<String> recents) {
  final out = <String>[];
  for (final e in recents) {
    if (out.length >= 6) break;
    if (!out.contains(e)) out.add(e);
  }
  for (final e in kQuickReactDefaults) {
    if (out.length >= 6) break;
    if (!out.contains(e)) out.add(e);
  }
  return out.take(6).toList();
}

/// The quick-react popup (`.quick-react-popup`, styles-features.css): a pill of
/// emoji buttons plus a "more" chevron (opens the full picker) and, for other
/// users' messages, a "menu" affordance (opens the context menu). Shown on
/// long-press of a message.
class QuickReactPopup extends StatelessWidget {
  const QuickReactPopup({
    super.key,
    required this.emojis,
    required this.onReact,
    required this.onMore,
    this.onMenu,
  });

  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;

  /// Opens the user/message context menu; null hides the affordance (own msg).
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xEB141423), // rgba(20,20,35,0.92)
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 32, offset: Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in emojis)
              _btn(child: Text(e, style: const TextStyle(fontSize: 22)),
                  onTap: () => onReact(e)),
            _btn(
              child: Icon(Icons.keyboard_arrow_down, size: 18, color: c.textDim),
              onTap: onMore,
            ),
            if (onMenu != null)
              _btn(
                child: Icon(Icons.more_vert, size: 18, color: c.textDim),
                onTap: onMenu!,
              ),
          ],
        ),
      ),
    );
  }

  Widget _btn({required Widget child, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: child,
      ),
    );
  }
}

/// Shows [QuickReactPopup] anchored above [anchorRect] (global coords), clamped
/// horizontally, dismissed on outside tap.
void showQuickReactPopup(
  BuildContext context, {
  required Rect anchorRect,
  required List<String> emojis,
  required ValueChanged<String> onReact,
  required VoidCallback onMore,
  VoidCallback? onMenu,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final size = MediaQuery.of(context).size;
  late OverlayEntry entry;
  void close() {
    if (entry.mounted) entry.remove();
  }

  final spaceAbove = anchorRect.top;
  final preferAbove = spaceAbove > 80;

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          top: preferAbove ? null : anchorRect.bottom + 6,
          bottom: preferAbove ? (size.height - anchorRect.top + 6) : null,
          child: Align(
            alignment:
                anchorRect.center.dx < size.width / 2 ? Alignment.centerLeft : Alignment.centerRight,
            child: QuickReactPopup(
              emojis: emojis,
              onReact: (e) {
                close();
                onReact(e);
              },
              onMore: () {
                close();
                onMore();
              },
              onMenu: onMenu == null
                  ? null
                  : () {
                      close();
                      onMenu();
                    },
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
}

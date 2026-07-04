import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/nym_icons.dart';
import '../messages/format/message_content.dart';

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

/// One row in the long-press quick-context-menu (`.quick-context-item`,
/// ui-context.js:1358-1450): a leading 16px icon + label, optionally tinted
/// (lightning / danger). [onTap] runs the action after the popup closes.
class QuickContextItem {
  const QuickContextItem({
    required this.label,
    required this.svg,
    required this.onTap,
    this.color = QuickContextItemColor.normal,
  });

  final String label;

  /// The leading glyph as a [NymIcons] SVG string.
  final String svg;
  final VoidCallback onTap;
  final QuickContextItemColor color;
}

/// Colour variants for [QuickContextItem] (`.lightning` #f7931a, `.danger`).
enum QuickContextItemColor { normal, lightning, danger }

/// The inline quick-context-menu (`.quick-context-menu`, styles-features.css
/// :2778-2845): a vertical card (`min-width:200px`, radius 14, `rgba(20,20,35,
/// 0.92)`, 4px padding) of labeled icon rows, shown below the quick-react pill
/// on long-press. Built from a gated item list mirroring ui-context.js
/// :1358-1450 (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete).
class QuickContextMenu extends StatelessWidget {
  const QuickContextMenu({super.key, required this.items});

  final List<QuickContextItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          // `.quick-context-menu` is `rgba(20,20,35,0.92)` by default, but
          // `body.solid-ui` (default ON) overrides it to `var(--glass-bg)` — the
          // opaque sidebar/header surface (#14141e dark, #ffffff light). Use the
          // mode-aware token so the menu is a light card in light mode instead of
          // a hardcoded dark slab.
          color: c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          // `--shadow-lg` softens in light mode (rgba(0,0,0,0.15) vs 0.4).
          boxShadow: [
            BoxShadow(
                color: c.isLight ? const Color(0x26000000) : const Color(0x66000000),
                blurRadius: 32,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final it in items) _QuickContextRow(item: it)],
        ),
      ),
    );
  }
}

class _QuickContextRow extends StatefulWidget {
  const _QuickContextRow({required this.item});
  final QuickContextItem item;

  @override
  State<_QuickContextRow> createState() => _QuickContextRowState();
}

class _QuickContextRowState extends State<_QuickContextRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final Color fg;
    final Color iconColor;
    switch (widget.item.color) {
      case QuickContextItemColor.lightning:
        fg = const Color(0xFFF7931A);
        iconColor = const Color(0xFFF7931A);
        break;
      case QuickContextItemColor.danger:
        fg = c.danger;
        iconColor = c.danger;
        break;
      case QuickContextItemColor.normal:
        fg = c.text;
        iconColor = c.textDim; // `.quick-context-item svg { color: text-dim }`
        break;
    }
    final hoverBg = widget.item.color == QuickContextItemColor.danger
        ? const Color(0x1FFF4444) // rgba(255,68,68,0.12) — both modes
        // `.quick-context-item:hover`: white@0.08 dark → black@0.06 light
        // (`body.light-mode .quick-context-item:hover`).
        : c.hoverOverlay;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? hoverBg : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            children: [
              NymSvgIcon(widget.item.svg, size: 16, color: iconColor),
              // `.nm-ico8` → margin-right:8px on the leading SVG.
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(color: fg, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quick-react popup (`.quick-react-popup`, styles-features.css
/// :2712-2776): a pill of emoji buttons (28px) plus exactly one trailing "more"
/// chevron with a left divider (`.quick-react-expand`) that opens the full
/// picker. Shown on long-press. The PWA pill carries no other affordance — the
/// labelled actions live in the separate `.quick-context-menu` card rendered
/// below (ui-context.js:1312-1323, 1452-1475).
class QuickReactPopup extends StatelessWidget {
  const QuickReactPopup({
    super.key,
    required this.emojis,
    required this.onReact,
    required this.onMore,
  });

  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          // `.quick-react-popup` is `rgba(20,20,35,0.92)` by default, but
          // `body.solid-ui` (default ON) overrides it to `var(--glass-bg)`
          // (#14141e dark, #ffffff light) — mode-aware so the pill is a light
          // surface in light mode.
          color: c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          // `--shadow-lg` softens in light mode (rgba(0,0,0,0.15) vs 0.4).
          boxShadow: [
            BoxShadow(
                color: c.isLight ? const Color(0x26000000) : const Color(0x66000000),
                blurRadius: 32,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in emojis)
              _EmojiButton(emoji: e, onTap: () => onReact(e)),
            // `.quick-react-expand`: chevron with a 1px left divider
            // (white@0.1 dark → black@0.1 light,
            // `body.light-mode .quick-react-expand`).
            Container(
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                      color: c.isLight
                          ? const Color(0x1A000000) // rgba(0,0,0,0.1)
                          : const Color(0x1AFFFFFF)), // rgba(255,255,255,0.1)
                ),
              ),
              child: _btn(
                child: Icon(Icons.keyboard_arrow_down, size: 18, color: c.textDim),
                onTap: onMore,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _btn({required Widget child, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: child,
      ),
    );
  }
}

/// A single 28px emoji button with hover-scale 1.3 / active-scale 0.95
/// (`.quick-react-emoji`, F13).
class _EmojiButton extends StatefulWidget {
  const _EmojiButton({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _scale = 1.3),
      onExit: (_) => setState(() => _scale = 1),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _scale = 0.95),
        onTapCancel: () => setState(() => _scale = 1),
        onTap: () {
          setState(() => _scale = 1);
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            // An exact `:shortcode:` recent renders as its custom-emoji image
            // (PWA ui-context.js:1313-1316 `renderCustomEmojiImg`, 30×30 via
            // `.quick-react-emoji .custom-emoji`, margin 0); unicode stays a
            // 28px text on the fast path. Reused by the call-chat quick-react
            // (surface #19).
            child: InlineEmojiText(
              text: widget.emoji,
              style: const TextStyle(fontSize: 28, height: 1),
              wholeStringOnly: true,
              emojiSize: 30,
              emojiMargin: EdgeInsets.zero,
              // `.quick-react-emoji .custom-emoji { vertical-align: middle }`
              // (styles-features.css:2747-2752).
              emojiAlignment: PlaceholderAlignment.middle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [QuickReactPopup] near [anchorRect] (global coords). The pressed
/// message is spotlit by dimming the rest of the screen (F9) and the popup
/// scales/rises in over 150ms (F13). When [contextItems] is non-empty an inline
/// [QuickContextMenu] is rendered just below the pill (F3, ui-context.js
/// :1452-1475); it is positioned below the pill, flipping above on overflow.
void showQuickReactPopup(
  BuildContext context, {
  required Rect anchorRect,
  required List<String> emojis,
  required ValueChanged<String> onReact,
  required VoidCallback onMore,
  @Deprecated('The PWA pill has no ⋮ menu button; this is ignored. '
      'Remove the onMenu: argument from the message_row call site.')
  VoidCallback? onMenu,
  Rect? spotlightRect,
  List<QuickContextItem> contextItems = const [],
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  void close() {
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) => _QuickReactOverlay(
      anchorRect: anchorRect,
      spotlightRect: spotlightRect,
      emojis: emojis,
      onReact: (e) {
        close();
        onReact(e);
      },
      onMore: () {
        close();
        onMore();
      },
      contextItems: contextItems
          .map((it) => QuickContextItem(
                label: it.label,
                svg: it.svg,
                color: it.color,
                onTap: () {
                  close();
                  it.onTap();
                },
              ))
          .toList(),
      onDismiss: close,
    ),
  );
  overlay.insert(entry);
}

/// The animated overlay body: an animated dim scrim (F9) + the pill + an
/// optional quick-context-menu, both entering with the PWA's scale/translate
/// transitions (F13). Positions the pill above/below the anchor and the menu
/// below the pill (flipping above on overflow).
class _QuickReactOverlay extends StatefulWidget {
  const _QuickReactOverlay({
    required this.anchorRect,
    required this.emojis,
    required this.onReact,
    required this.onMore,
    required this.contextItems,
    required this.onDismiss,
    this.spotlightRect,
  });

  final Rect anchorRect;

  /// The pressed MESSAGE's global bounds — the dim-scrim spotlight cutout (the
  /// PWA's `.long-press-highlight` row stays bright while the scroller dims,
  /// styles-features.css:2848-2863). Distinct from [anchorRect], which is a
  /// zero-size press-point rect the pill positions against (`left = clientX −
  /// w/2, top = clientY − 55`, ui-context.js:1330-1347). Null → the whole
  /// screen dims uniformly.
  final Rect? spotlightRect;
  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;
  final List<QuickContextItem> contextItems;
  final VoidCallback onDismiss;

  @override
  State<_QuickReactOverlay> createState() => _QuickReactOverlayState();
}

class _QuickReactOverlayState extends State<_QuickReactOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final r = widget.anchorRect;

    return Stack(
      children: [
        // Spotlight scrim (F9 `.has-long-press-highlight`): dim everything EXCEPT
        // the pressed message, which shows through a rounded cutout so it reads as
        // highlighted while the rest fades. Tap anywhere to dismiss.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: FadeTransition(
              opacity: _c,
              child: CustomPaint(
                size: Size.infinite,
                // The cutout is the pressed MESSAGE's rect (F9), not the
                // zero-size press-point anchor the pill lays out against.
                painter: _SpotlightPainter(
                    hole: widget.spotlightRect ?? Rect.zero),
              ),
            ),
          ),
        ),
        // Pill + (optional) quick-context-menu, anchored at the press point and
        // clamped fully on-screen (PWA `showQuickReactPopup`: centered on clientX,
        // top ≈ pressY − 55, never off the top/bottom/sides).
        CustomSingleChildLayout(
          delegate: _PressAnchorLayout(anchor: r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Pill: scale 0.8 / +8px → 1, opacity 0→1 (F13).
              _Enter(
                controller: _c,
                beginScale: 0.8,
                beginOffsetY: 8,
                child: QuickReactPopup(
                  emojis: widget.emojis,
                  onReact: widget.onReact,
                  onMore: widget.onMore,
                ),
              ),
              if (widget.contextItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                // Menu: scale 0.9 / -6px → 1, opacity 0→1 (F13).
                _Enter(
                  controller: _c,
                  beginScale: 0.9,
                  beginOffsetY: -6,
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(maxWidth: math.min(280, size.width - 20)),
                    child: QuickContextMenu(items: widget.contextItems),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Paints the dim scrim with a rounded-rect cutout over the pressed message, so
/// it stays bright (spotlit) while everything else dims — the native equivalent
/// of the PWA's `.long-press-highlight` raising the message above the dim layer.
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.hole});

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x59000000); // black @ 0.35
    if (hole == Rect.zero || hole.isEmpty) {
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    final screen = Path()..addRect(Offset.zero & size);
    final cut = Path()
      ..addRRect(RRect.fromRectAndRadius(
          hole.inflate(4), const Radius.circular(12)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, cut),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.hole != hole;
}

/// Positions the quick-react pill + context menu centered on the press point and
/// clamped so the whole stack stays fully on-screen (mirrors the PWA's
/// `clientX − w/2` / `pressY − 55` placement with 10px screen margins, but also
/// guards the bottom edge so a tall menu near the foot of the list isn't cut off).
class _PressAnchorLayout extends SingleChildLayoutDelegate {
  _PressAnchorLayout({required this.anchor});

  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // Loose height (the Column sizes to content; never force-clip it), capped
    // width so it can't exceed the viewport.
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - 20),
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double left = anchor.center.dx - childSize.width / 2;
    left = left.clamp(10.0, math.max(10.0, size.width - childSize.width - 10));
    double top = anchor.center.dy - 55;
    top = top.clamp(10.0, math.max(10.0, size.height - childSize.height - 10));
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_PressAnchorLayout old) => old.anchor != anchor;
}

/// Wraps [child] with the PWA's enter transition: a scale + vertical translate
/// driven by [controller] plus an opacity fade.
class _Enter extends StatelessWidget {
  const _Enter({
    required this.controller,
    required this.beginScale,
    required this.beginOffsetY,
    required this.child,
  });

  final AnimationController controller;
  final double beginScale;
  final double beginOffsetY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: controller, curve: Curves.easeOut);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, animatedChild) {
        final t = curve.value;
        final scale = beginScale + (1 - beginScale) * t;
        final dy = beginOffsetY * (1 - t);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topCenter,
              child: animatedChild,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

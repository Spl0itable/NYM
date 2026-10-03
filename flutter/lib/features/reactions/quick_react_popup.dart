import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/nym_icons.dart';
import '../messages/format/message_content.dart';
import '../../widgets/anchored_popup.dart';

/// Default quick-react emojis, used to pad recents to six.
const List<String> kQuickReactDefaults = ['👍', '❤️', '😂', '🔥', '👎', '😮'];

/// Recents first, padded with defaults, deduped, capped at six.
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

/// One long-press quick-context row; [onTap] runs after the popup closes.
class QuickContextItem {
  const QuickContextItem({
    required this.label,
    required this.svg,
    required this.onTap,
    this.color = QuickContextItemColor.normal,
  });

  final String label;

  final String svg;
  final VoidCallback onTap;
  final QuickContextItemColor color;
}

/// Color variants: report `--warning`, danger.
enum QuickContextItemColor { normal, report, danger }

/// Long-press quick-context card shown below the quick-react pill.
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
          // Solid-ui (default) uses the opaque, mode-aware glass background.
          color: c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          boxShadow: [
            BoxShadow(
                color: c.isLight
                    ? const Color(0x26000000)
                    : const Color(0x66000000),
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
      case QuickContextItemColor.report:
        fg = c.warning;
        iconColor = c.warning;
        break;
      case QuickContextItemColor.danger:
        fg = c.danger;
        iconColor = c.danger;
        break;
      case QuickContextItemColor.normal:
        fg = c.text;
        iconColor = c.textDim;
        break;
    }
    final hoverBg = widget.item.color == QuickContextItemColor.danger
        ? const Color(0x1FFF4444)
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

/// Long-press pill of emoji buttons plus one trailing chevron that opens the full picker.
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
          color: c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          boxShadow: [
            BoxShadow(
                color: c.isLight
                    ? const Color(0x26000000)
                    : const Color(0x66000000),
                blurRadius: 32,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in emojis)
              _EmojiButton(emoji: e, onTap: () => onReact(e)),
            Container(
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                      color: c.isLight
                          ? const Color(0x1A000000)
                          : const Color(0x1AFFFFFF)),
                ),
              ),
              child: _btn(
                child:
                    Icon(Icons.keyboard_arrow_down, size: 18, color: c.textDim),
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
            // An exact `:shortcode:` recent renders as its custom-emoji image; unicode stays text.
            child: InlineEmojiText(
              text: widget.emoji,
              style: const TextStyle(fontSize: 28, height: 1),
              wholeStringOnly: true,
              emojiSize: 30,
              emojiMargin: EdgeInsets.zero,
              emojiAlignment: PlaceholderAlignment.middle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the pill near [anchorRect], dimming everything but the pressed message, with [contextItems] below it.
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

/// Dim scrim, pill and optional context menu, which flips above the pill on overflow.
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

  /// Pressed message bounds for the spotlight cutout; [anchorRect] is the zero-size press point; null dims everything.
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
        // Dim everything except the pressed message; tap anywhere to dismiss.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: FadeTransition(
              opacity: _c,
              child: CustomPaint(
                size: Size.infinite,
                painter:
                    _SpotlightPainter(hole: widget.spotlightRect ?? Rect.zero),
              ),
            ),
          ),
        ),
        // Anchored at the press point and clamped fully on-screen.
        CustomSingleChildLayout(
          delegate: PointPopupLayout(
            anchor: r.center,
            insets: popupInsetsOf(context),
            offset: const Offset(0, -55),
            centerX: true,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
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
                _Enter(
                  controller: _c,
                  beginScale: 0.9,
                  beginOffsetY: -6,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: math.min(280, size.width - 20)),
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

/// Dim scrim with a rounded cutout so the pressed message stays bright.
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.hole});

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x59000000);
    if (hole == Rect.zero || hole.isEmpty) {
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    final screen = Path()..addRect(Offset.zero & size);
    final cut = Path()
      ..addRRect(
          RRect.fromRectAndRadius(hole.inflate(4), const Radius.circular(12)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, cut),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.hole != hole;
}

/// Scale, vertical translate and opacity enter transition driven by [controller].
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

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import 'shop_catalog.dart';
import 'shop_models.dart';

/// Renders a catalog item's inline SVG icon, tinted to [color]. The SVGs use
/// `stroke="currentColor"` / `fill="currentColor"`, so we apply a colour filter
/// matching the web's `currentColor` inheritance.
class ShopSvgIcon extends StatelessWidget {
  const ShopSvgIcon({
    super.key,
    required this.svg,
    required this.size,
    required this.color,
  });

  final String svg;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

/// The `.flair-badge` — a flair item's SVG tinted to its themed colour, sized
/// like the web (`font-size: 20px`). Genesis stamps its edition number.
class FlairBadge extends StatelessWidget {
  const FlairBadge({
    super.key,
    required this.flairId,
    this.edition,
    this.size = 20,
  });

  final String flairId;
  final int? edition;
  final double size;

  /// Themed flair colours, mirroring the `.flair-X` CSS rules.
  static const Map<String, Color> colors = {
    'flair-crown': Color(0xFFFFD700),
    'flair-diamond': Color(0xFF00FFFF),
    'flair-skull': Color(0xFFFF0000),
    'flair-star': Color(0xFFFFFF00),
    'flair-lightning': Color(0xFFF7931A),
    'flair-heart': Color(0xFFFF5577),
    'flair-mask': Color(0xFFCFCFCF),
    'flair-rocket': Color(0xFFFF6B6B),
    'flair-shield': Color(0xFF4ADE80),
    'flair-flame': Color(0xFFFF8C00),
    'flair-snowflake': Color(0xFF7DD3FC),
    'flair-moon': Color(0xFFFFE066),
    'flair-sun': Color(0xFFFFC300),
    'flair-leaf': Color(0xFF4ADE80),
    'flair-music': Color(0xFFA78BFA),
    'flair-eye': Color(0xFFD4C5F9),
    'flair-anchor': Color(0xFF93C5FD),
    'flair-gem': Color(0xFFFF4D6D),
    'flair-genesis': Color(0xFFFFC440),
  };

  @override
  Widget build(BuildContext context) {
    final svg = ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final color = colors[flairId] ?? context.nym.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: ShopSvgIcon(svg: svg, size: size, color: color),
    );
  }
}

/// The `.supporter-badge` — gold trophy + "SUPPORTER" pill
/// (`css/styles-features.css` `.supporter-badge`).
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.height = 18});

  final double height;

  static const Color _gold = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x1FFFD700), Color(0x0FFFD700)],
        ),
        border: Border.all(color: const Color(0x4DFFD700)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShopSvgIcon(svg: ShopCatalog.trophyIcon, size: 14, color: _gold),
          const SizedBox(width: 5),
          const Text(
            'SUPPORTER',
            style: TextStyle(
              color: _gold,
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small message-style text preview (`.shop-item-preview` for styles) showing
/// the sample text in the style's colour + glow.
class MessageStylePreview extends StatelessWidget {
  const MessageStylePreview({super.key, required this.styleId, this.text = 'Your_Nick'});

  final String styleId;
  final String text;

  @override
  Widget build(BuildContext context) {
    final v = ShopCatalog.styleVisuals[styleId];
    final c = context.nym;
    if (v == null) {
      return Text(text, style: TextStyle(color: c.text));
    }
    final base = TextStyle(
      color: v.color,
      fontWeight: FontWeight.w600,
      fontFamily: v.monospace ? 'monospace' : null,
      shadows: v.glow != null
          ? [Shadow(color: v.glow!, blurRadius: 10)]
          : null,
    );
    if (v.gradient != null) {
      return ShaderMask(
        shaderCallback: (rect) => LinearGradient(colors: v.gradient!)
            .createShader(rect),
        child: Text(text, style: base.copyWith(color: Colors.white)),
      );
    }
    return Text(text, style: base);
  }
}

/// A cosmetic preview chip — a rounded box with the aura accent border/glow
/// (`.message.cosmetic-X`).
class CosmeticPreview extends StatelessWidget {
  const CosmeticPreview({super.key, required this.cosmeticId, this.text = 'Your message'});

  final String cosmeticId;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final v = ShopCatalog.cosmeticVisuals[cosmeticId];
    if (cosmeticId == 'cosmetic-redacted') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        constraints: const BoxConstraints(minWidth: 120),
        child: const Text('████████', style: TextStyle(color: Colors.transparent)),
      );
    }
    if (v == null) {
      return Text(text, style: TextStyle(color: c.text));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: v.gradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: v.gradient!,
              )
            : null,
        border: Border(left: BorderSide(color: v.accent, width: 3)),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(color: v.accent.withValues(alpha: 0.32), blurRadius: 20),
        ],
      ),
      child: Text(text, style: TextStyle(color: c.text, fontSize: 13)),
    );
  }
}

/// Renders the preview region for a single shop item card depending on its type.
class ShopItemPreview extends StatelessWidget {
  const ShopItemPreview({super.key, required this.item});

  final ShopItem item;

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case 'message-style':
        return MessageStylePreview(styleId: item.id);
      case 'nickname-flair':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your_Nick',
                style: TextStyle(fontWeight: FontWeight.w600)),
            FlairBadge(flairId: item.id),
          ],
        );
      case 'supporter':
        return const SupporterBadge();
      case 'cosmetic':
        return CosmeticPreview(cosmeticId: item.id);
      default:
        return const SizedBox.shrink();
    }
  }
}

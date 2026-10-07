import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../i18n/i18n.dart';
import '../toasts/toast_center.dart';
import 'cosmetics.dart'
    show
        CosmeticAura,
        CosmeticOverlayPainter,
        StyleWatermarkLayer,
        cosmeticAuraFor,
        messageStyleDecoration;
import 'shop_catalog.dart';
import 'shop_models.dart';
import '../../widgets/common/nym_tooltip.dart';

/// Renders a catalog item's inline SVG tinted to [color] via `currentColor`.
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
    // `currentColor` theming avoids the per-icon saveLayer a srcIn colorFilter forces on every row.
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: color),
    );
  }
}

/// Flair glow: CSS `text-shadow` is inert on a path SVG so only `filter: drop-shadow` renders, in both modes.
class _FlairGlow {
  const _FlairGlow({this.textShadows = const [], this.dropShadows = const []});

  /// Recorded for reference only; never painted.
  final List<(Color, double)> textShadows;

  /// `filter: drop-shadow` blurs (color, blurRadius), both modes.
  final List<(Color, double)> dropShadows;

  /// Only the drop-shadow copies render.
  List<(Color, double)> shadowsFor({required bool isLight}) => dropShadows;
}

/// Flair SVG tinted to its themed color with its glow; Genesis stamps its edition number.
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

  /// Exact CSS flair colors.
  static const Map<String, Color> colors = {
    'flair-crown': Color(0xFFFFD700),
    'flair-diamond': Color(0xFF00FFFF),
    'flair-skull': Color(0xFFFF0000),
    'flair-star': Color(0xFFFFFF00),
    'flair-lightning': Color(0xFFF7931A),
    'flair-heart': Color(0xFFFF1493),
    'flair-mask': Color(0xFFFFFFFF),
    'flair-rocket': Color(0xFFFF6B6B),
    'flair-shield': Color(0xFF52FF9D),
    'flair-flame': Color(0xFFFF7A1A),
    'flair-snowflake': Color(0xFF7FDFFF),
    'flair-moon': Color(0xFFCDD6FF),
    'flair-sun': Color(0xFFFFC93C),
    'flair-leaf': Color(0xFF5FD35F),
    'flair-music': Color(0xFFB388FF),
    'flair-eye': Color(0xFFE0F7FF),
    'flair-anchor': Color(0xFF5B9DFF),
    'flair-gem': Color(0xFFFF3B6B),
    'flair-genesis': Color(0xFFFFDF6B),
  };

  /// Darker light-mode flair colors, for legibility on light surfaces.
  static const Map<String, Color> lightColors = {
    'flair-crown': Color(0xFFB8960A),
    'flair-diamond': Color(0xFF0088AA),
    'flair-skull': Color(0xFFCC0000),
    'flair-star': Color(0xFF8A7200),
    'flair-lightning': Color(0xFFC47A15),
    'flair-heart': Color(0xFFCC0066),
    'flair-mask': Color(0xFF333333),
    'flair-rocket': Color(0xFFCC3333),
    'flair-shield': Color(0xFF228855),
    'flair-flame': Color(0xFFCC5500),
    'flair-snowflake': Color(0xFF0077AA),
    'flair-moon': Color(0xFF4A4FA0),
    'flair-sun': Color(0xFFB8860A),
    'flair-leaf': Color(0xFF2E8B2E),
    'flair-music': Color(0xFF7A3FCC),
    'flair-eye': Color(0xFF1F7A9C),
    'flair-anchor': Color(0xFF2855A3),
    'flair-gem': Color(0xFFCC1F4F),
    'flair-genesis': Color(0xFFB8860A),
  };

  /// Per-flair glow; a CSS `0 0 Npx` blur maps to blurRadius N.
  static const Map<String, _FlairGlow> _glows = {
    'flair-crown': _FlairGlow(
      textShadows: [(Color(0x80FFD700), 10.0)],
    ),
    'flair-diamond': _FlairGlow(
      textShadows: [(Color(0x8000FFFF), 10.0)],
      dropShadows: [(Color(0xF2B4FFFF), 7.0)],
    ),
    'flair-skull': _FlairGlow(
      textShadows: [(Color(0x80FF0000), 10.0)],
    ),
    'flair-star': _FlairGlow(
      textShadows: [(Color(0x80FFFF00), 10.0)],
      dropShadows: [(Color(0xE6FFFF00), 6.0)],
    ),
    'flair-lightning': _FlairGlow(
      textShadows: [(Color(0x80F7931A), 10.0)],
    ),
    'flair-heart': _FlairGlow(
      textShadows: [(Color(0x80FF1493), 10.0)],
    ),
    'flair-mask': _FlairGlow(
      textShadows: [(Color(0x80FFFFFF), 10.0)],
    ),
    'flair-rocket': _FlairGlow(
      textShadows: [(Color(0x99FF6B6B), 10.0)],
    ),
    'flair-shield': _FlairGlow(
      textShadows: [(Color(0x9952FF9D), 10.0)],
    ),
    'flair-flame': _FlairGlow(
      textShadows: [(Color(0x99FF7A1A), 10.0)],
      dropShadows: [(Color(0xE6FF8C28), 6.0)],
    ),
    'flair-snowflake': _FlairGlow(
      textShadows: [(Color(0x997FDFFF), 10.0)],
    ),
    'flair-moon': _FlairGlow(
      textShadows: [(Color(0x99CDD6FF), 10.0)],
    ),
    'flair-sun': _FlairGlow(
      textShadows: [(Color(0xB3FFC93C), 12.0)],
    ),
    'flair-leaf': _FlairGlow(
      textShadows: [(Color(0x995FD35F), 10.0)],
    ),
    'flair-music': _FlairGlow(
      textShadows: [(Color(0x99B388FF), 10.0)],
    ),
    'flair-eye': _FlairGlow(
      textShadows: [(Color(0x9978DCFF), 10.0)],
    ),
    'flair-anchor': _FlairGlow(
      textShadows: [(Color(0x995B9DFF), 10.0)],
    ),
    'flair-gem': _FlairGlow(
      textShadows: [(Color(0x99FF3B6B), 10.0)],
    ),
    'flair-genesis': _FlairGlow(
      textShadows: [
        (Color(0xB3FFD700), 8.0),
        (Color(0x66FFAA00), 16.0),
      ],
      dropShadows: [(Color(0xE6FFC800), 7.0)],
    ),
  };

  @override
  Widget build(BuildContext context) {
    // flutter_svg drops `<text>`, so the Genesis number is overlaid as a Flutter `Text`.
    final showGenesisNumber =
        flairId == 'flair-genesis' && edition != null && edition! > 0;
    final svg = showGenesisNumber
        ? ShopCatalog.flairIcon(flairId)
        : ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final isLight = context.nym.isLight;
    // Light mode uses darker colors; the drop-shadow glow isn't reset, so it survives.
    final color = (isLight ? lightColors[flairId] : colors[flairId]) ??
        context.nym.primary;
    final shadows = _glows[flairId]?.shadowsFor(isLight: isLight) ?? const [];
    final icon = ShopSvgIcon(svg: svg, size: size, color: color);
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: (shadows.isEmpty && !showGenesisNumber)
          ? icon
          : Stack(
              alignment: Alignment.center,
              children: [
                for (final (glowColor, blur) in shadows)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ImageFiltered(
                        // Match Flutter's Shadow sigma so the glow reads like a CSS blur of the same radius.
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: Shadow.convertRadiusToSigma(blur),
                          sigmaY: Shadow.convertRadiusToSigma(blur),
                        ),
                        child:
                            ShopSvgIcon(svg: svg, size: size, color: glowColor),
                      ),
                    ),
                  ),
                icon,
                // Edition number centered near the pyramid base (~0.31x size font, y≈0.42).
                if (showGenesisNumber)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: const Alignment(0, 0.42),
                        child: Text(
                          '$edition',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: color,
                            fontSize: size * 0.31,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Gold trophy plus "SUPPORTER" pill.
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.height = 18});

  final double height;

  static const Color _gold = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    // Light mode uses a darker amber pill so the gold reads on a light surface.
    final isLight = context.nym.isLight;
    final gradient = isLight
        ? const [Color(0x26B48C00), Color(0x14B48C00)]
        : const [Color(0x1FFFD700), Color(0x0FFFD700)];
    final border = isLight ? const Color(0xFFB8960A) : const Color(0x4DFFD700);
    final textColor = isLight ? const Color(0xFF7A5C00) : _gold;
    final iconColor = isLight ? const Color(0xFF9A7800) : _gold;
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Gold glow behind the trophy, kept in light mode.
          Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: Shadow.convertRadiusToSigma(4),
                      sigmaY: Shadow.convertRadiusToSigma(4),
                    ),
                    child: const ShopSvgIcon(
                      svg: ShopCatalog.trophyIcon,
                      size: 14,
                      color: Color(0x99FFD700),
                    ),
                  ),
                ),
              ),
              ShopSvgIcon(
                  svg: ShopCatalog.trophyIcon, size: 14, color: iconColor),
            ],
          ),
          const SizedBox(width: 5),
          Text(
            tr('SUPPORTER'),
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              letterSpacing: 1,
              // No declared weight, so 400.
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live message-style preview using the same mode-aware color, glow, background and watermark as the chat bubble.
class ShopStyleBubblePreview extends StatelessWidget {
  const ShopStyleBubblePreview({
    super.key,
    required this.styleId,
    this.text = 'Preview message',
    this.bubble = true,
    this.sampleIsChild = true,
  });

  final String styleId;
  final String text;

  /// Whether the sample is a child span (satoshi shows orange) or bare body text (container color).
  final bool sampleIsChild;

  /// Bubble layout draws the rounded translucent bubble; IRC is a bare padded line.
  final bool bubble;

  // The demo uses the real message-style rules, so only satoshi/eclipse/crt paint a content background.

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Mode-aware decoration, so light mode shows the PWA's light style colors.
    final deco = messageStyleDecoration(styleId, isLight: c.isLight);
    // Mode-aware watermark; the dark tiles would be invisible on a light card.
    final watermark = deco?.watermark;
    if (deco == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 13));
    }
    // Glyph shadows are already nulled in light mode; fire/ice use a brighter bubble color.
    final base = TextStyle(
      // Child samples use the child color (satoshi orange), bare text the container color.
      color: sampleIsChild
          ? deco.previewColorFor(bubble: bubble)
          : deco.textColorFor(bubble: bubble),
      // 13px normal weight; only satoshi's child spans are bold.
      fontSize: 13,
      fontWeight: (deco.bold || (sampleIsChild && deco.childColor != null))
          ? FontWeight.bold
          : FontWeight.normal,
      fontFamily: deco.monospace ? 'monospace' : null,
      shadows: deco.textShadows,
    );
    Widget label;
    if (deco.gradient != null) {
      label = ShaderMask(
        shaderCallback: (rect) =>
            LinearGradient(colors: deco.gradient!).createShader(rect),
        child: Text(text, style: base.copyWith(color: Colors.white)),
      );
      // A mask would clip the glow, so paint a shadow-only copy behind the gradient text.
      final glow = deco.gradientGlow;
      if (glow != null) {
        label = Stack(
          children: [
            Text(
              text,
              style: base.copyWith(
                color: const Color(0x00000000),
                shadows: [glow],
              ),
            ),
            label,
          ],
        );
      }
    } else {
      label = Text(text, style: base);
    }
    // The style's own content background for this layout, or null.
    final styleBg = deco.contentBackgroundFor(bubble: bubble);
    // IRC: bare text with no bubble fill; only the style's own background tints it.
    if (!bubble) {
      // No watermark or background: just the padded glyph line.
      if (watermark == null && styleBg == null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: label,
        );
      }
      // The watermark fills the padding box, tiling from its top-left corner.
      return Container(
        decoration: BoxDecoration(color: styleBg),
        clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
        child: Stack(
          children: [
            if (watermark != null)
              Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: label,
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        // Bubble layout: default translucent bubble, overridden by a style background.
        color: styleBg ??
            (c.isLight
                ? const Color(0x1A000000)
                : const Color(0x24FFFFFF)),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
      child: Stack(
        children: [
          // The watermark tiles from the bubble's top-left, under the padding.
          if (watermark != null)
            Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
          Padding(
            // A style's own padding outranks the default bubble padding.
            padding:
                deco.contentPadding ?? const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: label,
          ),
        ],
      ),
    );
  }
}

/// Composes [CosmeticAura]s onto [child] like the chat bubble: fill, IRC accent, glows, watermark and overlay.
class ShopAuraBubble extends StatelessWidget {
  const ShopAuraBubble({
    super.key,
    required this.auras,
    required this.child,
    required this.bubble,
    this.padding,
    this.defaultFill = true,
    this.styleActive = false,
  });

  final List<CosmeticAura> auras;
  final Widget child;

  /// Bubble mode decorates the rounded content; IRC mode paints the flat row.
  final bool bubble;

  final EdgeInsetsGeometry? padding;

  /// Whether to paint the default bubble fill under aura-less fills.
  final bool defaultFill;

  /// An active message style drops some aura layers (gold wash, frost fill, cosmic starfield, hologram sheen).
  final bool styleActive;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    if (auras.isEmpty) return child;
    final last = auras.last;

    // Bubble paints gold's gradient or frost's wash or the default; IRC paints the row gradient; an active style drops some.
    List<Color>? fillGradient;
    Color? fillColor;
    if (bubble) {
      if (last.bubblePaintsGradient && !styleActive) {
        fillGradient = last.bubbleFillGradient;
      } else {
        fillColor = (styleActive ? null : last.background) ??
            (defaultFill
                ? (c.isLight
                    ? const Color(0x1A000000)
                    : const Color(0x24FFFFFF))
                : null);
      }
    } else {
      fillGradient = last.gradient;
      fillColor = styleActive ? null : last.background;
    }

    // Every aura's outer glow at the layout's color and blur.
    final shadows = <BoxShadow>[
      for (final a in auras)
        if (a.glowColorFor(bubble: bubble) != null &&
            a.glowBlurFor(bubble: bubble) > 0)
          BoxShadow(
            color: a.glowColorFor(bubble: bubble)!,
            blurRadius: a.glowBlurFor(bubble: bubble),
          ),
    ];

    // IRC left accent from the last aura that has one.
    final borderAccent = bubble
        ? null
        : auras.reversed
            .map((a) => a.borderAccent)
            .firstWhere((b) => b != null, orElse: () => null);

    // First watermark and overlay auras; the cosmic bubble starfield only tiles without an active style.
    CosmeticAura? watermarkAura;
    for (final a in auras) {
      if (a.watermark != null && (a.edgeWatermark || !bubble || !styleActive)) {
        watermarkAura = a;
        break;
      }
    }
    CosmeticAura? overlayAura;
    for (final a in auras) {
      if (a.hasOverlay) {
        overlayAura = a;
        break;
      }
    }

    // IRC rows are square since a left-only border forbids a radius.
    final radius = bubble
        ? const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          )
        : BorderRadius.zero;

    final needsStack = watermarkAura != null || overlayAura != null;
    final inner =
        padding == null ? child : Padding(padding: padding!, child: child);
    // Row-level IRC auras span the width; content-level auras hug their child.
    final expand = !bubble && auras.any((a) => a.borderAccent != null);
    return Container(
      width: expand ? double.infinity : null,
      decoration: BoxDecoration(
        color: fillGradient == null ? fillColor : null,
        gradient: fillGradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: fillGradient,
              )
            : null,
        border: borderAccent != null
            ? Border(left: BorderSide(color: borderAccent, width: 3))
            : null,
        borderRadius: bubble ? radius : null,
        boxShadow: shadows.isEmpty ? null : shadows,
      ),
      clipBehavior: needsStack ? Clip.antiAlias : Clip.none,
      child: !needsStack
          ? inner
          : Stack(
              children: [
                if (watermarkAura != null)
                  Positioned.fill(
                    child: StyleWatermarkLayer(
                      watermark: watermarkAura.watermark!,
                      edgeOnly: watermarkAura.edgeWatermark,
                    ),
                  ),
                inner,
                if (overlayAura != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: CosmeticOverlayPainter(
                          aura: overlayAura,
                          radius: radius,
                          bubble: bubble,
                          // Drops the hologram fill and sheen when a style is active.
                          styleActive: styleActive,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Live cosmetic preview built from the same [CosmeticAura] as the chat bubble, plus the redacted blackout.
class ShopCosmeticBubblePreview extends StatelessWidget {
  const ShopCosmeticBubblePreview({
    super.key,
    required this.cosmeticId,
    this.text = 'Preview message',
    this.bubble = true,
  });

  final String cosmeticId;
  final String text;

  /// Chat-bubbles vs IRC layout.
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Redacted: a translucent blank bar, always shown blanked.
    if (cosmeticId == 'cosmetic-redacted') {
      return Container(
        constraints: const BoxConstraints(minWidth: 120),
        // Bubble padding and radius outrank the redacted styling in bubble mode.
        padding: bubble
            ? const EdgeInsets.fromLTRB(12, 8, 12, 6)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.isLight
              ? const Color(0x1F000000)
              : const Color(0x26FFFFFF),
          borderRadius: bubble
              ? const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                )
              : BorderRadius.circular(8),
        ),
        // Transparent text reserves a real message's line height.
        child: Text(
          text,
          style: const TextStyle(color: Colors.transparent, fontSize: 13),
        ),
      );
    }
    final aura = cosmeticAuraFor(cosmeticId, isLight: c.isLight);
    if (aura == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 13));
    }
    final label = Text(text, style: TextStyle(color: c.text, fontSize: 13));
    // Row-level IRC auras span the demo width with the sample centered.
    final rowLevel = !bubble && aura.borderAccent != null;
    return ShopAuraBubble(
      auras: [aura],
      bubble: bubble,
      padding: bubble
          ? const EdgeInsets.fromLTRB(12, 8, 12, 6)
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: rowLevel ? Center(child: label) : label,
    );
  }
}

/// Preview box for flair and supporter rows only; style/cosmetic demos and bundle chips render bare.
class ShopPreviewBox extends StatelessWidget {
  const ShopPreviewBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      constraints: const BoxConstraints(minHeight: 50),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: c.glassBorder),
        borderRadius: NymRadius.rsm,
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: c.text, fontSize: 12),
        textAlign: TextAlign.center,
        child: child,
      ),
    );
  }
}

/// Per-type preview: flair and supporter rows boxed, style and cosmetic demos bare and centered.
class ShopItemPreview extends StatelessWidget {
  const ShopItemPreview({super.key, required this.item, this.bubble = true});

  final ShopItem item;

  /// The user's chat layout, so demos render as they would in chat.
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case 'message-style':
        // Bare, centered demo with no box.
        return Center(
          child: ShopStyleBubblePreview(styleId: item.id, bubble: bubble),
        );
      case 'nickname-flair':
        // The Genesis card stamps a sample edition (#69).
        final sampleEdition = item.id == 'flair-genesis' ? 69 : null;
        // Regular weight nym; only the limited card and supporter demo bold it.
        return ShopPreviewBox(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Your_Nick '),
              FlairBadge(flairId: item.id, edition: sampleEdition),
            ],
          ),
        );
      case 'supporter':
        // Boxed nym and badge row, then a bare supporter-style bubble.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShopPreviewBox(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Your_Nick ',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SupporterBadge(),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Center(child: _SupporterStyleBubble(bubble: bubble)),
          ],
        );
      case 'cosmetic':
        return Center(
          child: ShopCosmeticBubblePreview(cosmeticId: item.id, bubble: bubble),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Supporter-style demo: gold text over a gold wash with a left bar (IRC) or a gold-tinted bubble; darker in light mode.
class _SupporterStyleBubble extends StatelessWidget {
  const _SupporterStyleBubble({this.bubble = true});

  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final isLight = context.nym.isLight;
    final text = Text(
      tr('Preview message'),
      style: TextStyle(
        color: isLight ? const Color(0xFF8A6D00) : const Color(0xFFFFD700),
        // 13px normal weight.
        fontSize: 13,
        shadows: isLight
            ? null
            : const [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
      ),
    );
    if (!bubble) {
      // IRC wash and bar span the demo width with the sample centered.
      return Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? const [Color(0x0FB48C00), Color(0x05B48C00)]
                : const [Color(0x0DFFD700), Color(0x05FFD700)],
          ),
          border: Border(
            left: BorderSide(
              color:
                  isLight ? const Color(0xFFB8960A) : const Color(0xFFFFD700),
              width: 3,
            ),
          ),
        ),
        child: text,
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0x14B49600)
            : const Color(0x1FFFD700),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: text,
    );
  }
}

/// Limited supply badge in green/blue/red tiers; light mode swaps only the text color.
class ShopSupplyBadge extends StatelessWidget {
  const ShopSupplyBadge({super.key, required this.availability});

  final ShopAvailability availability;

  static const _available = (
    fg: Color(0xFF52FF9D),
    lightFg: Color(0xFF1F8A4C),
    bg: Color(0x1F52FF9D),
    border: Color(0x5952FF9D),
  );
  static const _soon = (
    fg: Color(0xFF7FDFFF),
    lightFg: Color(0xFF1F6F8A),
    bg: Color(0x1F7FDFFF),
    border: Color(0x597FDFFF),
  );
  static const _danger = (
    fg: Color(0xFFFF6B6B),
    lightFg: Color(0xFFC0392B),
    bg: Color(0x1FFF6B6B),
    border: Color(0x59FF6B6B),
  );

  @override
  Widget build(BuildContext context) {
    if (availability.label.isEmpty) return const SizedBox.shrink();
    final tier = switch (availability.state) {
      ShopAvailabilityState.available => _available,
      ShopAvailabilityState.soon => _soon,
      ShopAvailabilityState.ended || ShopAvailabilityState.soldout => _danger,
    };
    final fg = context.nym.isLight ? tier.lightFg : tier.fg;
    return Container(
      // Callers provide the collapsed margins.
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: tier.bg,
        border: Border.all(color: tier.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        availability.label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Bundle "Save X%" badge plus component chips (max 10, then "+N more"), rendered bare.
class ShopBundlePreview extends StatelessWidget {
  const ShopBundlePreview({super.key, required this.item});

  final ShopItem item;

  static const _chipCap = 10;

  @override
  Widget build(BuildContext context) {
    final all = ShopCatalog.bundleComponents(item.id);
    final shown = all.take(_chipCap).toList();
    final savePct = ShopCatalog.bundleSavePercent(item.id);
    final value = ShopCatalog.bundleValue(item.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (savePct > 0) ...[
          // Left-aligned in the card flow, not centered.
          Align(
            alignment: Alignment.centerLeft,
            child: ShopSupplyBadge(
              availability: ShopAvailability(
                ShopAvailabilityState.available,
                tr('Save {pct}% · {value} sats value',
                    {'pct': savePct, 'value': value}),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final id in shown) _BundleChip(itemId: id),
            if (all.length > _chipCap) _BundleChip.more(all.length - _chipCap),
          ],
        ),
      ],
    );
  }
}

/// Component icon and name in a secondary-tinted pill.
class _BundleChip extends StatelessWidget {
  const _BundleChip({required this.itemId}) : extra = 0;
  const _BundleChip.more(this.extra) : itemId = null;

  final String? itemId;
  final int extra;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final item = itemId == null ? null : ShopCatalog.byId(itemId!);
    final label = item?.name ?? tr('+{n} more', {'n': extra});
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.10),
        border: Border.all(color: c.secondaryA(0.30)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item != null) ...[
            ShopSvgIcon(svg: item.icon, size: 14, color: c.text),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(color: c.text, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Gold `#{n}/{max}` edition stamp; darker amber without glow in light mode.
class ShopEditionNumber extends StatelessWidget {
  const ShopEditionNumber({super.key, required this.edition, this.editionMax});

  final int edition;
  final int? editionMax;

  @override
  Widget build(BuildContext context) {
    final isLight = context.nym.isLight;
    return Text(
      '#$edition${editionMax != null ? '/$editionMax' : ''}',
      style: TextStyle(
        color: isLight ? const Color(0xFF8A6D00) : const Color(0xFFFFDF6B),
        fontSize: 12,
        fontWeight: FontWeight.w700,
        shadows: isLight
            ? null
            : const [Shadow(color: Color(0x66FFD700), blurRadius: 6)],
      ),
    );
  }
}

/// Tap-to-copy recovery code row.
class RecoveryCodeRow extends StatelessWidget {
  const RecoveryCodeRow({
    super.key,
    required this.code,
    this.label = 'Recovery code',
  });

  final String code;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child:
                Text(label, style: TextStyle(color: c.textDim, fontSize: 10)),
          ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) {
              showToast(tr('Copied recovery code'));
            }
          },
          child: NymTooltip(
            message: tr('Click to copy'),
            child: Text(
              code,
              style: TextStyle(
                color: c.textBright,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 45° "LEGENDARY" corner ribbon; wrap the card in a clipping Stack.
class ShopLegendaryRibbon extends StatelessWidget {
  const ShopLegendaryRibbon({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 24,
      right: -48,
      child: Transform.rotate(
        angle: 45 * math.pi / 180,
        child: Container(
          width: 160,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFFB340), Color(0xFFFF7AD9)],
            ),
            boxShadow: [
              BoxShadow(
                  color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 1))
            ],
          ),
          child: Text(
            tr('LEGENDARY'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF1A1320),
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

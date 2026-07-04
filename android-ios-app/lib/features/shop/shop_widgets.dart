import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'cosmetics.dart'
    show
        CosmeticAura,
        CosmeticOverlayPainter,
        StyleWatermarkLayer,
        cosmeticAuraFor,
        messageStyleDecoration;
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

/// A flair's `.flair-X` glow — blurred tinted copies of the glyph painted behind
/// the crisp icon. The CSS expresses this as two SEPARATE properties:
///   * `text-shadow` — declared on every `.flair-X`, BUT the flair glyph is an
///     inline path-only `<svg>` (no `<text>`), and CSS `text-shadow` shadows
///     text runs only, never replaced inline-SVG paths. So the declared halo is
///     INERT in the browser: the PWA renders these copies for NO flair, in
///     either mode. We keep the values recorded for fidelity/reference, but they
///     are never painted.
///   * `filter: drop-shadow(...)` — only on the brighter star/flame/diamond/
///     genesis. `filter` DOES apply to a replaced inline SVG, so this is the
///     only glow the PWA actually renders. The light-mode overrides reset
///     `color`/`text-shadow` but NOT `filter`, so it survives into light mode.
/// Keeping the two lists distinct documents that asymmetry exactly.
class _FlairGlow {
  const _FlairGlow({this.textShadows = const [], this.dropShadows = const []});

  /// `text-shadow` blurs (colour, blurRadius). Recorded for reference only —
  /// inert on a path SVG, so never painted (see class doc).
  final List<(Color, double)> textShadows;

  /// `filter: drop-shadow` blurs (colour, blurRadius) — both modes.
  final List<(Color, double)> dropShadows;

  /// The glow copies to paint. Only the `filter: drop-shadow` copies render in
  /// the PWA — `text-shadow` does not shadow a path SVG — so we paint the
  /// `drop-shadow` set in BOTH modes and ignore the inert `text-shadow` halo.
  List<(Color, double)> shadowsFor({required bool isLight}) => dropShadows;
}

/// The `.flair-badge` — a flair item's SVG tinted to its themed colour, sized
/// like the web (`font-size: 20px`), with the per-flair `.flair-X` glow. Genesis
/// stamps its edition number.
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

  /// Themed flair colours — the EXACT `.flair-X { color }` CSS hex
  /// (`styles-features.css:323-356, 646-711, 1213`).
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

  /// Light-mode `.flair-X` colours (`body.light-mode .flair-X`,
  /// styles-themes-responsive.css:765-985) — darker / desaturated for legibility
  /// on a light surface; the CSS also drops the glow (`text-shadow: none`).
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

  /// The `.flair-X` glow, split into its CSS `text-shadow` halo (dark only) and
  /// `filter: drop-shadow` (both modes — survives `body.light-mode`). Each entry
  /// is a blurred tinted glyph copy; the CSS `0 0 Npx` blur maps directly to a
  /// Gaussian `blurRadius` of N. Values are the exact CSS rgba()s
  /// (`styles-features.css:323-356, 646-711, 1213-1216`).
  static const Map<String, _FlairGlow> _glows = {
    'flair-crown': _FlairGlow(
      textShadows: [(Color(0x80FFD700), 10.0)], // rgba(255,215,0,.5)
    ),
    'flair-diamond': _FlairGlow(
      textShadows: [(Color(0x8000FFFF), 10.0)], // rgba(0,255,255,.5)
      dropShadows: [(Color(0xF2B4FFFF), 7.0)], // rgba(180,255,255,.95)
    ),
    'flair-skull': _FlairGlow(
      textShadows: [(Color(0x80FF0000), 10.0)], // rgba(255,0,0,.5)
    ),
    'flair-star': _FlairGlow(
      textShadows: [(Color(0x80FFFF00), 10.0)], // rgba(255,255,0,.5)
      dropShadows: [(Color(0xE6FFFF00), 6.0)], // rgba(255,255,0,.9)
    ),
    'flair-lightning': _FlairGlow(
      textShadows: [(Color(0x80F7931A), 10.0)], // rgba(247,147,26,.5)
    ),
    'flair-heart': _FlairGlow(
      textShadows: [(Color(0x80FF1493), 10.0)], // rgba(255,20,147,.5)
    ),
    'flair-mask': _FlairGlow(
      textShadows: [(Color(0x80FFFFFF), 10.0)], // rgba(255,255,255,.5)
    ),
    'flair-rocket': _FlairGlow(
      textShadows: [(Color(0x99FF6B6B), 10.0)], // rgba(255,107,107,.6)
    ),
    'flair-shield': _FlairGlow(
      textShadows: [(Color(0x9952FF9D), 10.0)], // rgba(82,255,157,.6)
    ),
    'flair-flame': _FlairGlow(
      textShadows: [(Color(0x99FF7A1A), 10.0)], // rgba(255,122,26,.6)
      dropShadows: [(Color(0xE6FF8C28), 6.0)], // rgba(255,140,40,.9)
    ),
    'flair-snowflake': _FlairGlow(
      textShadows: [(Color(0x997FDFFF), 10.0)], // rgba(127,223,255,.6)
    ),
    'flair-moon': _FlairGlow(
      textShadows: [(Color(0x99CDD6FF), 10.0)], // rgba(205,214,255,.6)
    ),
    'flair-sun': _FlairGlow(
      textShadows: [(Color(0xB3FFC93C), 12.0)], // rgba(255,201,60,.7) 12px
    ),
    'flair-leaf': _FlairGlow(
      textShadows: [(Color(0x995FD35F), 10.0)], // rgba(95,211,95,.6)
    ),
    'flair-music': _FlairGlow(
      textShadows: [(Color(0x99B388FF), 10.0)], // rgba(179,136,255,.6)
    ),
    'flair-eye': _FlairGlow(
      textShadows: [(Color(0x9978DCFF), 10.0)], // rgba(120,220,255,.6)
    ),
    'flair-anchor': _FlairGlow(
      textShadows: [(Color(0x995B9DFF), 10.0)], // rgba(91,157,255,.6)
    ),
    'flair-gem': _FlairGlow(
      textShadows: [(Color(0x99FF3B6B), 10.0)], // rgba(255,59,107,.6)
    ),
    'flair-genesis': _FlairGlow(
      textShadows: [
        (Color(0xB3FFD700), 8.0), // rgba(255,215,0,.7)
        (Color(0x66FFAA00), 16.0), // rgba(255,170,0,.4)
      ],
      dropShadows: [(Color(0xE6FFC800), 7.0)], // rgba(255,200,0,.9)
    ),
  };

  @override
  Widget build(BuildContext context) {
    // Genesis stamps an edition number. The PWA injects it as an SVG `<text>`,
    // but `flutter_svg`/`vector_graphics` silently drops `<text>` elements, so
    // we render the plain icon (NO dead `<text>`) and overlay the number as a
    // real Flutter `Text` below (F2).
    final showGenesisNumber =
        flairId == 'flair-genesis' && edition != null && edition! > 0;
    final svg = showGenesisNumber
        ? ShopCatalog.flairIcon(flairId)
        : ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final isLight = context.nym.isLight;
    // Light mode swaps to the darker `body.light-mode .flair-X` colour; the
    // `.flair-X` `text-shadow` halo is inert on a path SVG (never painted in
    // either mode), and the `filter: drop-shadow` on star/flame/diamond/genesis
    // is NOT reset by the light-mode rules, so it survives into light mode —
    // `_FlairGlow.shadowsFor` returns exactly those drop-shadow copies.
    final color =
        (isLight ? lightColors[flairId] : colors[flairId]) ?? context.nym.primary;
    final shadows = _glows[flairId]?.shadowsFor(isLight: isLight) ?? const [];
    final icon = ShopSvgIcon(svg: svg, size: size, color: color);
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: (shadows.isEmpty && !showGenesisNumber)
          ? icon
          : Stack(
              alignment: Alignment.center,
              children: [
                // Blurred tinted glyph copies (`filter: drop-shadow`).
                for (final (glowColor, blur) in shadows)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ImageFiltered(
                        // Match Flutter's Shadow blur sigma (`Shadow.convertRadius
                        // ToSigma`) so an SVG glow reads like a `text-shadow`/
                        // `drop-shadow` of the same CSS blur radius.
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: Shadow.convertRadiusToSigma(blur),
                          sigmaY: Shadow.convertRadiusToSigma(blur),
                        ),
                        child: ShopSvgIcon(svg: svg, size: size, color: glowColor),
                      ),
                    ),
                  ),
                icon,
                // Genesis edition number, mirroring the PWA's SVG `<text>` at
                // `x=12 y=19.4 font-size=7.5` on the 24-unit viewBox: horizontally
                // centred, sitting near the base of the pyramid. `font-size 7.5`
                // over the 24.1-unit viewBox ≈ 0.31·size; the digit's visual
                // centre falls at ~0.71 of the badge height (Alignment y≈0.42).
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

/// The `.supporter-badge` — gold trophy + "SUPPORTER" pill
/// (`css/styles-features.css` `.supporter-badge`).
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.height = 18});

  final double height;

  static const Color _gold = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    // Light mode (`body.light-mode .supporter-badge*`): a darker amber pill —
    // bg rgba(180,140,0,.15→.08), border #b8960a, text #7a5c00, icon #9a7800 —
    // so the gold reads on a light surface. Dark mode keeps the bright gold.
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
          // `.supporter-badge-icon svg { filter: drop-shadow(0 0 4px
          // rgba(255,215,0,.6)) }` (styles-features.css:1462-1466) — a gold
          // glow behind the trophy glyph. The light-mode rules recolour the
          // icon but do NOT reset the filter, so the glow survives light mode.
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
                      color: Color(0x99FFD700), // rgba(255,215,0,.6)
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
            'SUPPORTER',
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              letterSpacing: 1,
              // `.supporter-badge-text` declares no font-weight → 400.
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// A live message-bubble preview for a message style (F4 / `_shopStyleDemo`):
/// a real `.message-content`-equivalent container rendering "Preview message"
/// in the style's colour + glow with the translucent content background and —
/// for the textured styles — the SAME mode-aware tiled `--style-pattern` SVG
/// the rendered chat message uses ([messageStyleDecoration]'s watermark via
/// [StyleWatermarkLayer]), so the card matches the bubble in BOTH themes.
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

  /// Whether the sample text is an inner `> *` CHILD (the shop item-card demo
  /// wraps "Preview message" in a `<span>`, shop.js `_shopStyleDemo`:724) or a
  /// BARE body text node (the "This is how your messages look." active-items block
  /// puts the text directly in `.message-content`, shop.js:964). It only matters
  /// for the satoshi container/child split: a child shows the orange `#f7931a`,
  /// the bare body shows the white/brown container colour.
  final bool sampleIsChild;

  /// When true (chat-bubbles layout) the demo `.message-content` is the rounded
  /// translucent bubble (`body.chat-bubbles .message-content`); when false (IRC
  /// layout) it is the bare style-coloured glyph line with only `padding: 6px
  /// 10px` (`body:not(.chat-bubbles) .shop-msg-demo .message-content`,
  /// styles-features.css:1415), no bubble background, no radius.
  final bool bubble;

  // NOTE: the shop demo renders `<div class="message style-X">` (shop.js
  // `_shopStyleDemo`, :724), so it is styled by the REAL `.message.style-X
  // .message-content` rules — NOT the `.style-preview-X` classes (which carry a
  // tinted card wash but are never applied by the shop render; the `preview`
  // catalog field is unused). So the wash styles (ocean/sakura/galaxy/toxic/
  // blood/royal/circuit) paint NO content background — only their glowing text +
  // tiled `--style-pattern` watermark — over the layout's default bubble fill.
  // Only satoshi/eclipse/crt carry a real content background (contentBackground).

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Resolve the MODE-AWARE decoration (same source the chat bubble uses), so
    // the card preview switches to the PWA's `body.light-mode` style colours /
    // dropped glow in light mode instead of showing the unreadable dark neons.
    final deco = messageStyleDecoration(styleId, isLight: c.isLight);
    // The MODE-AWARE tiled `--style-pattern` (deco.watermark) — light mode swaps
    // the darker light-theme tiles (ghost #223044, matrix #006600, …) exactly
    // like the chat bubble; reading the dark map directly would tile invisible
    // white ghosts on a light card.
    final watermark = deco?.watermark;
    if (deco == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 13));
    }
    // The glyph shadow(s): explicit multi-offset (glitch) or the single glow,
    // already nulled in light mode by `messageStyleDecoration`. fire/ice paint a
    // brighter glyph in the bubble than IRC (`body.chat-bubbles .message.style-X
    // .message-content { color }`), so resolve the colour per the user's layout.
    final base = TextStyle(
      // A wrapped `<span>` sample is an inner `> *` child — for satoshi the bold
      // orange `#f7931a`/`#c47a15`; a bare body node uses the white/brown container
      // colour. `previewColorFor` returns the child colour for the split styles,
      // `textColorFor` the container body colour.
      color: sampleIsChild
          ? deco.previewColorFor(bubble: bubble)
          : deco.textColorFor(bubble: bubble),
      // `.shop-msg-demo .message-content { font-size: 13px }` (styles-features
      // .css:1406-1413), normal weight — only satoshi's inner `> *` children are
      // bold (`font-weight: bold`, :572), which the wrapped-span sample hits.
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
      // The aurora blue glow (`.style-preview-aurora { text-shadow: 0 0 10px
      // rgba(91,140,255,.3) }`, styles-features.css:630-636; dark mode only —
      // the light preview resets it). The mask would clip a shadow away, so
      // paint a shadow-only transparent copy behind the gradient text, exactly
      // like the chat bubble does.
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
    // The style's own in-chat `.message-content { background }` for this layout
    // (satoshi/eclipse/crt, plus aurora's TRANSPARENT bubble replacement); null
    // for every other style — they tint via text + watermark, not a content
    // background, exactly as the rendered chat message does.
    final styleBg = deco.contentBackgroundFor(bubble: bubble);
    // IRC layout: `body:not(.chat-bubbles) .shop-msg-demo .message-content` is
    // bare text with only `padding: 6px 10px` — NO rounded bubble, NO default
    // `white@.14` fill. Only the style's own `.message-content { background }`
    // (satoshi/eclipse/crt) still tints it (styleBg), with no radius.
    if (!bubble) {
      // No watermark and no content bg → just the bare padded glyph line.
      if (watermark == null && styleBg == null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: label,
        );
      }
      // The style still carries its tiled `--style-pattern` watermark (ocean,
      // sakura, …) and/or content bg (satoshi/eclipse/crt) in IRC — just no
      // rounded bubble. The watermark Stack is clipped to the content rect.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: styleBg),
        clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (watermark != null)
              Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
            label,
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        // Bubble layout: `body.chat-bubbles .message-content` is the rounded
        // translucent bubble (`background: rgba(255,255,255,.14)`, radius 16 /
        // top-left 4 — styles-features.css:3603-3617). A style with its own
        // content background (satoshi/eclipse/crt) or a card wash paints over it.
        color: styleBg ??
            (c.isLight
                ? const Color(0x1A000000) // light: others → black@.10
                : const Color(0x24FFFFFF)), // dark: white@.14
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (watermark != null)
            Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
          label,
        ],
      ),
    );
  }
}

/// Composes one or more [CosmeticAura]s onto [child] the same way the chat
/// bubble does: the fill (bubble gradient / flat wash / default translucent
/// bubble), the IRC `border-left` accent, every aura's outer glow, the tiled
/// watermark (frost edge snowflakes / cosmic starfield) and the
/// prism-ring / hologram / inset-ring overlay painter.
class ShopAuraBubble extends StatelessWidget {
  const ShopAuraBubble({
    super.key,
    required this.auras,
    required this.child,
    required this.bubble,
    this.padding,
    this.defaultFill = true,
  });

  final List<CosmeticAura> auras;
  final Widget child;

  /// Chat-bubbles vs IRC layout: bubble mode decorates the rounded translucent
  /// `.message-content`; IRC mode paints border-left + gradient wash on the
  /// flat row (`body:not(.chat-bubbles) .message.cosmetic-aura-*`).
  final bool bubble;

  final EdgeInsetsGeometry? padding;

  /// Whether to paint the layout's default translucent bubble fill under
  /// aura-less fills (false when [child] already draws its own bubble, e.g. the
  /// active-items preview wrapping a styled content bubble).
  final bool defaultFill;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    if (auras.isEmpty) return child;
    final last = auras.last;

    // Fill: the bubble paints the aura gradient only when the PWA bubble has
    // one (gold); otherwise the aura's flat wash (frost) or the layout default.
    // IRC paints the 135° row gradient / flat wash with no default fill.
    List<Color>? fillGradient;
    Color? fillColor;
    if (bubble) {
      if (last.bubblePaintsGradient) {
        fillGradient = last.bubbleFillGradient;
      } else {
        fillColor = last.background ??
            (defaultFill
                ? (c.isLight ? const Color(0x1A000000) : const Color(0x24FFFFFF))
                : null);
      }
    } else {
      fillGradient = last.gradient;
      fillColor = last.background;
    }

    // Every aura's outer glow (`0 0 {blur}px {color}`), at the layout's
    // colour + blur (light gold's bubble glow is `.15` vs the IRC `.12`).
    final shadows = <BoxShadow>[
      for (final a in auras)
        if (a.glowColorFor(bubble: bubble) != null &&
            a.glowBlurFor(bubble: bubble) > 0)
          BoxShadow(
            color: a.glowColorFor(bubble: bubble)!,
            blurRadius: a.glowBlurFor(bubble: bubble),
          ),
    ];

    // IRC `border-left: 3px solid …` accent (last aura carrying one).
    final borderAccent = bubble
        ? null
        : auras.reversed
            .map((a) => a.borderAccent)
            .firstWhere((b) => b != null, orElse: () => null);

    // Watermark (first aura carrying one) + overlay (first prism/holo/ring aura).
    CosmeticAura? watermarkAura;
    for (final a in auras) {
      if (a.watermark != null) {
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

    // The rounded bubble radius (4 / 16, like the demo bubbles) — IRC rows are
    // square. A non-uniform Border(left) forbids a radius, so IRC keeps zero.
    final radius = bubble
        ? const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          )
        : BorderRadius.zero;

    final needsStack = watermarkAura != null || overlayAura != null;
    final inner = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    // IRC row-level auras (`body:not(.chat-bubbles) .message.cosmetic-X` —
    // gold/neon/phoenix/cosmic, the ones carrying a border-left) decorate the
    // BLOCK message row, so the wash/bar/glow spans the available width; the
    // content-level auras (rainbow/frost/hologram style the inline-block
    // `.message-content` in both layouts) hug their child.
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
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// A live message-bubble preview for a cosmetic aura (F4 / `_shopCosmeticDemo`):
/// composes the SAME mode-aware [CosmeticAura] the chat bubble uses (ring +
/// glow + border-left + gradient + frost snowflake edges / cosmic starfield /
/// prism ring / hologram sheen) via [ShopAuraBubble], plus the redacted blackout.
class ShopCosmeticBubblePreview extends StatelessWidget {
  const ShopCosmeticBubblePreview({
    super.key,
    required this.cosmeticId,
    this.text = 'Preview message',
    this.bubble = true,
  });

  final String cosmeticId;
  final String text;

  /// Chat-bubbles vs IRC layout (see [ShopAuraBubble.bubble]).
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Redacted: the `.cosmetic-redacted-message` blank — a translucent bar
    // (`background: rgba(255,255,255,.15)` dark / `rgba(0,0,0,.12)` light —
    // styles-features.css:1424-1435 + themes:954-957 — color transparent,
    // radius xs, min-width 120px). The shop demo applies the class immediately
    // (shop.js:779), so the card always shows the blanked state.
    if (cosmeticId == 'cosmetic-redacted') {
      return Container(
        constraints: const BoxConstraints(minWidth: 120),
        // In chat-bubbles mode the demo content is still the rounded bubble —
        // `body.chat-bubbles .message-content` (padding 8px 12px 6px, radius
        // 16 / top-left 4) outspecifies `.cosmetic-redacted-message`'s
        // `--radius-xs`; only the IRC layout keeps the shop-demo `6px 10px`
        // padding + the redacted radius-xs 8.
        padding: bubble
            ? const EdgeInsets.fromLTRB(12, 8, 12, 6)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.isLight
              ? const Color(0x1F000000) // rgba(0,0,0,.12)
              : const Color(0x26FFFFFF), // rgba(255,255,255,.15)
          borderRadius: bubble
              ? const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                )
              : BorderRadius.circular(8),
        ),
        // Transparent text reserves the 1.2em line-height of a real message.
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
    // An IRC row-level aura spans the demo width ([ShopAuraBubble] expands it)
    // with the inline-block sample centered inside (`.shop-msg-demo
    // { text-align: center }`); content-level auras hug the text.
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

/// The `.shop-item-preview` box (styles-features.css:181-193): full-width,
/// `padding: 12px`, `rgba(255,255,255,.03)` fill, glass border, radius-sm,
/// `min-height: 50px`, flex-centered content, 12px `--text` type (no light
/// override — the tint stays in both modes). ONLY the flair nym rows and the
/// supporter-badge rows sit in this box in the PWA — the message-style /
/// cosmetic demos and the bundle chips render BARE in the card.
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

/// Renders the preview region for a single shop item card depending on its
/// type, with the PWA's box-vs-bare split: the flair nym row (and the
/// supporter nym+badge row) sit in the `.shop-item-preview` box, while the
/// message-style / cosmetic demos are BARE `.shop-msg-demo` blocks — centered,
/// no card-within-a-card box (shop.js `_shopStyleDemo`/`_shopCosmeticDemo`).
class ShopItemPreview extends StatelessWidget {
  const ShopItemPreview({super.key, required this.item, this.bubble = true});

  final ShopItem item;

  /// The user's current chat layout (chat-bubbles vs IRC). Threaded into the
  /// live message demos so the card preview renders the cosmetic AS IT WOULD
  /// APPEAR in the user's layout — the `.shop-msg-demo` reuses the real
  /// `.message`/`.message-content` classes, which the PWA styles by
  /// `body.chat-bubbles` vs `body:not(.chat-bubbles)`. The flair/supporter-badge
  /// nym rows are identical in both layouts (plain `.shop-item-preview` text).
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case 'message-style':
        // Bare `.shop-msg-demo` — block, `text-align: center`, no box.
        return Center(
          child: ShopStyleBubblePreview(styleId: item.id, bubble: bubble),
        );
      case 'nickname-flair':
        // The Genesis card stamps a sample edition (#69) on the badge, matching
        // `_renderLimitedCard`.
        final sampleEdition = item.id == 'flair-genesis' ? 69 : null;
        // The flair-tab preview nym is REGULAR weight (`<span>Your_Nick …`,
        // shop.js:759) — only the limited-tab flair card (:864) and the
        // supporter demo (:786) wrap it in `<strong>`. The markup keeps a
        // literal space between the nym and the badge's 5px margin.
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
        // TWO blocks (shop.js:783): the boxed `.shop-item-preview` nym+badge
        // row, then a separate BARE `.shop-msg-demo` supporter-style bubble.
        // Box `margin-bottom: 10px` collapses with the demo's 10px top margin.
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
            // supporter-style demo bubble (gold text + wash).
            Center(child: _SupporterStyleBubble(bubble: bubble)),
          ],
        );
      case 'cosmetic':
        // Bare `.shop-msg-demo`, centered — no box.
        return Center(
          child: ShopCosmeticBubblePreview(cosmeticId: item.id, bubble: bubble),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// The supporter-style demo bubble (`.message.supporter-style`): gold glyphs +
/// soft glow over the layout-appropriate surface.
///
/// * IRC (`body:not(.chat-bubbles) .message.supporter-style`,
///   styles-features.css:1473): a 135° gold wash (`rgba(255,215,0,.05)` →
///   `.02`) + a 3px gold left bar on the flat row, no radius. Light mode
///   (themes:934-936): wash `rgba(180,140,0,.06→.02)`, bar `#b8960a`.
/// * Bubble (`body.chat-bubbles .message.supporter-style .message-content`,
///   styles-features.css:3692): a flat `rgba(255,215,0,.12)` fill on the rounded
///   bubble (radius 16 / top-left 4), no left bar. Light mode (themes:1421):
///   `rgba(180,150,0,.08)`.
/// Text: dark `#ffd700` + 8px gold glow; light `#8a6d00`, no glow (themes:939).
class _SupporterStyleBubble extends StatelessWidget {
  const _SupporterStyleBubble({this.bubble = true});

  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final isLight = context.nym.isLight;
    final text = Text(
      'Preview message',
      style: TextStyle(
        color: isLight ? const Color(0xFF8A6D00) : const Color(0xFFFFD700),
        // `.shop-msg-demo .message-content { font-size: 13px }`, normal weight.
        fontSize: 13,
        shadows: isLight
            ? null
            : const [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
      ),
    );
    if (!bubble) {
      // IRC: the wash + 3px gold bar sit on the BLOCK `.message` row, so they
      // span the demo width with the inline-block sample centered inside
      // (`.shop-msg-demo { text-align: center }`).
      return Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? const [Color(0x0FB48C00), Color(0x05B48C00)] // .06 → .02
                : const [Color(0x0DFFD700), Color(0x05FFD700)], // .05 → .02
          ),
          border: Border(
            left: BorderSide(
              color: isLight
                  ? const Color(0xFFB8960A)
                  : const Color(0xFFFFD700),
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
            ? const Color(0x14B49600) // rgba(180,150,0,.08)
            : const Color(0x1FFFD700), // gold@.12
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

/// The limited-tab supply/availability badge (F5 — `.shop-supply-badge
/// shop-supply-{state}`). Three colour tiers: available green `#52ff9d`, soon
/// blue `#7fdfff`, ended/soldout red `#ff6b6b` (`styles-features.css:1342-1359`).
/// Light mode swaps ONLY the text colour (`body.light-mode .shop-supply-*`,
/// styles-themes-responsive.css:1044-1047): available `#1f8a4c`, soon
/// `#1f6f8a`, ended/soldout `#c0392b`; the bg/border rgba tints stay.
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
      ShopAvailabilityState.ended ||
      ShopAvailabilityState.soldout =>
        _danger,
    };
    final fg = context.nym.isLight ? tier.lightFg : tier.fg;
    return Container(
      // `.shop-supply-badge { margin: 6px 0; padding: 2px 10px }`
      // (styles-features.css:1332-1340). The 6px CSS margins collapse with the
      // neighbours' margins, so callers provide the collapsed gaps instead.
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

/// The bundle savings badge + content chips (F6 — `_renderBundleCard`):
/// a "Save X% · N sats value" badge above each component as a
/// `.shop-bundle-chip` (icon + name, capped at 10 with "+N more"). Renders
/// BARE in the card — the PWA `.shop-bundle-contents` has no box.
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
          // The save badge is an inline-block div in the card's LEFT-aligned
          // flow (`.shop-supply-badge`), not centered; its 6px bottom margin
          // collapses with `.shop-bundle-contents`' 8px top margin → 8px gap.
          Align(
            alignment: Alignment.centerLeft,
            child: ShopSupplyBadge(
              availability: ShopAvailability(
                ShopAvailabilityState.available,
                'Save $savePct% · $value sats value',
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
            if (all.length > _chipCap)
              _BundleChip.more(all.length - _chipCap),
          ],
        ),
      ],
    );
  }
}

/// A single `.shop-bundle-chip`: the component's SVG icon + name in a rounded
/// secondary-tinted pill (`styles-features.css:1369-1383`).
class _BundleChip extends StatelessWidget {
  const _BundleChip({required this.itemId}) : extra = 0;
  const _BundleChip.more(this.extra) : itemId = null;

  final String? itemId;
  final int extra;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final item = itemId == null ? null : ShopCatalog.byId(itemId!);
    final label = item?.name ?? '+$extra more';
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

/// The gold edition-number stamp (`#{n}/{max}`, `.shop-edition-no`,
/// `styles-features.css:1385-1390`): gold `#ffdf6b`, 12px 700, soft gold glow.
/// Light mode (`body.light-mode .shop-edition-no`, themes:1048): darker amber
/// `#8a6d00`, no glow (`text-shadow: none`).
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

/// A click-to-copy recovery-code row (F9/F10 — `.nm-shop-6`/`.nm-shop-7`):
/// a "Recovery code" label over the monospace code; tapping copies it.
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied recovery code')),
              );
            }
          },
          child: Tooltip(
            message: 'Click to copy',
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

/// The 45deg "LEGENDARY" corner ribbon (F14 — `.shop-legendary-ribbon`):
/// gradient `#ffb340→#ff7ad9`, dark text, 8px 800-weight, rotated 45deg in the
/// top-right corner. Wrap the card in a `Stack` and clip it.
class ShopLegendaryRibbon extends StatelessWidget {
  const ShopLegendaryRibbon({super.key});

  @override
  Widget build(BuildContext context) {
    // top:24px right:-48px width:160px rotate(45deg) (styles-features.css:1312).
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
            boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: const Text(
            'LEGENDARY',
            textAlign: TextAlign.center,
            style: TextStyle(
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

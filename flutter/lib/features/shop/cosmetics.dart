import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_theme.dart' show kMonoFont, kSansSymFont;
import '../../models/user.dart';
import '../../services/api/storage_sync.dart' show ShopStatusActive;
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'shop_catalog.dart';
import 'shop_controller.dart';
import 'shop_models.dart';
import 'shop_widgets.dart';

/// Resolved shop cosmetics for a user: live shop state for self, presence/shop-status fields for others.
class UserCosmetics {
  const UserCosmetics({
    this.styleId,
    this.flairIds = const [],
    this.supporter = false,
    this.cosmetics = const [],
    this.genesisEdition,
  });

  /// Active message-style id (e.g. `style-satoshi`), or null.
  final String? styleId;

  /// Active flair ids in record order; one badge per id, though self is capped to one.
  final List<String> flairIds;

  /// The last flair id, for surfaces showing a single badge.
  String? get flairId => flairIds.isNotEmpty ? flairIds.last : null;

  /// True when the supporter badge is owned and active.
  final bool supporter;

  /// Active special-cosmetic ids, composed onto the message alongside the style.
  final List<String> cosmetics;

  /// Genesis edition stamped on the `flair-genesis` badge, if known.
  final int? genesisEdition;

  bool get isEmpty =>
      styleId == null && flairIds.isEmpty && !supporter && cosmetics.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// Redacted privacy cosmetic: blanks content and author after a delay.
  bool get isRedacted => cosmetics.contains('cosmetic-redacted');

  static const UserCosmetics none = UserCosmetics();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserCosmetics &&
          other.styleId == styleId &&
          other.supporter == supporter &&
          other.genesisEdition == genesisEdition &&
          listEquals(other.flairIds, flairIds) &&
          listEquals(other.cosmetics, cosmetics);

  @override
  int get hashCode => Object.hash(styleId, supporter, genesisEdition,
      Object.hashAll(flairIds), Object.hashAll(cosmetics));
}

/// Self from the shop controller; others from D1 shop-status, falling back to presence fields. Pure, safe in `build`.
UserCosmetics resolveCosmetics(WidgetRef ref, String pubkey) {
  final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    return _selfCosmetics(ref.read(shopControllerProvider).active);
  }
  final fromD1 = ref.read(otherUsersShopProvider)[pubkey.toLowerCase()];
  if (fromD1 != null) return userCosmeticsFromStatus(fromD1);
  final user = ref.read(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
}

/// Self cosmetics from the live shop state, including cosmetics and Genesis edition.
UserCosmetics _selfCosmetics(ActiveItems active) {
  return UserCosmetics(
    styleId: active.style,
    // Self flair is capped to the last activated id.
    flairIds: active.flair.isNotEmpty ? [active.flair.last] : const [],
    supporter: active.supporter,
    cosmetics: active.cosmetics,
    genesisEdition: active.editions['flair-genesis'],
  );
}

/// Cosmetics from a [User]'s presence fields.
UserCosmetics userCosmeticsFromUser(User? user) {
  if (user == null) return UserCosmetics.none;
  return UserCosmetics(
    styleId: (user.shopStyle != null && user.shopStyle!.isNotEmpty)
        ? user.shopStyle
        : null,
    // Presence carries a single flair.
    flairIds: (user.shopFlair != null && user.shopFlair!.isNotEmpty)
        ? [user.shopFlair!]
        : const [],
    supporter: user.isSupporter,
    cosmetics: user.shopCosmetics,
    genesisEdition: user.shopEdition,
  );
}

/// Cosmetics from an authoritative shop-status record, keeping the full flair array and Genesis edition.
UserCosmetics userCosmeticsFromStatus(ShopStatusActive a) {
  return UserCosmetics(
    styleId: (a.style != null && a.style!.isNotEmpty) ? a.style : null,
    flairIds: a.flair,
    supporter: a.supporter,
    cosmetics: a.cosmetics,
    genesisEdition: a.editions['flair-genesis'],
  );
}

/// Watchable per-pubkey cosmetics; queues a batched shop-status fetch (on a microtask) for unknown others.
final userCosmeticsProvider =
    Provider.family<UserCosmetics, String>((ref, pubkey) {
  final selfPubkey = ref.watch(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    return _selfCosmetics(ref.watch(shopControllerProvider).active);
  }
  final key = pubkey.toLowerCase();
  final fromD1 = ref.watch(otherUsersShopProvider)[key];
  if (fromD1 != null) return userCosmeticsFromStatus(fromD1);
  // Unknown to D1: queue a lookup and use presence fields meanwhile.
  final other = ref.read(otherUsersShopProvider.notifier);
  scheduleMicrotask(() => other.queue(key));
  final user = ref.watch(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
});

/// Flair and supporter badges following a nym; renders nothing without either.
class CosmeticNymBadges extends StatelessWidget {
  const CosmeticNymBadges({
    super.key,
    required this.cosmetics,
    this.edition,
    // 20px glyph, matching the PWA on every nym.
    this.flairSize = 20,
    this.supporterHeight = 18,
  });

  final UserCosmetics cosmetics;

  /// Genesis edition to stamp on a numbered flair, if known.
  final int? edition;

  final double flairSize;
  final double supporterHeight;

  @override
  Widget build(BuildContext context) {
    // One badge per active flair id in order, skipping ids the catalog doesn't know.
    final flairIds = [
      for (final id in cosmetics.flairIds)
        if (id.isNotEmpty && ShopCatalog.byId(id) != null) id,
    ];
    final supporter = cosmetics.supporter;
    if (flairIds.isEmpty && !supporter) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in flairIds)
          FlairBadge(
            flairId: id,
            // Stamp the Genesis edition when none was passed.
            edition: id == 'flair-genesis'
                ? (edition ?? cosmetics.genesisEdition)
                : null,
            size: flairSize,
          ),
        if (supporter) SupporterBadge(height: supporterHeight),
      ],
    );
  }
}

/// Genesis holders bold the whole nym; the suffix stays 400.
bool hasGenesisFlair(UserCosmetics cosmetics) =>
    cosmetics.flairIds.contains('flair-genesis');

/// Native rendering of a `.message.style-X` rule; the glow is a glyph text-shadow, never a box shadow.
class MessageStyleDecoration {
  const MessageStyleDecoration({
    required this.textColor,
    this.glow,
    this.glowShadows,
    this.gradient,
    this.gradientGlow,
    this.contentBackground,
    this.bubbleContentBackground,
    this.bubbleOnlyContentBackground = false,
    this.contentPadding,
    this.transparentBubble = false,
    this.backgroundGradient,
    this.bubbleTextColor,
    this.childColor,
    this.borderAccent,
    this.monospace = false,
    this.bold = false,
    this.glyphShadows,
    this.watermark,
  });

  final Color textColor;
  final Color? glow;

  /// The full multi-layer text-shadow stack; [glow] is the single-layer fallback.
  final List<Shadow>? glowShadows;

  final List<Color>? gradient;

  /// Aurora's blue glow painted behind its gradient text.
  final Shadow? gradientGlow;

  final Color? contentBackground;

  /// Bubble-layout content background when it differs from [contentBackground]; null uses that in both.
  final Color? bubbleContentBackground;

  /// [contentBackground] applies only in bubble layout (supporter); IRC gets no content plate.
  final bool bubbleOnlyContentBackground;

  /// Style padding over the layout default (satoshi), outranking the bubble padding in both layouts.
  final EdgeInsets? contentPadding;

  /// Aurora in bubbles keeps the default plate, so [contentBackgroundFor] returns null.
  final bool transparentBubble;

  /// 135° gradient painted on the IRC row (supporter); bubbles use [contentBackground].
  final List<Color>? backgroundGradient;

  /// Bubble-only text color (fire/ice); null means the same in both layouts.
  final Color? bubbleTextColor;

  /// Inner-element and shop-demo color when it differs from the body [textColor] (satoshi only).
  final Color? childColor;

  final Color? borderAccent;
  final bool monospace;

  /// Bold glyphs (satoshi).
  final bool bold;

  /// Explicit glyph shadows overriding [glow], e.g. glitch's red/cyan split.
  final List<Shadow>? glyphShadows;

  /// Repeating texture behind the content, or null.
  final StyleWatermark? watermark;

  /// Glyph shadows: glitch's split, else the layered stack, else a single soft glow.
  List<Shadow>? get textShadows {
    if (glyphShadows != null) return glyphShadows;
    if (glowShadows != null) return glowShadows;
    return glow != null ? [Shadow(color: glow!, blurRadius: 10)] : null;
  }

  /// Body (container) text color for the layout.
  Color textColorFor({required bool bubble}) =>
      bubble ? (bubbleTextColor ?? textColor) : textColor;

  /// Content background for the layout; non-null replaces the default bubble fill, null keeps it.
  Color? contentBackgroundFor({required bool bubble}) {
    if (bubble) {
      // Aurora keeps the default bubble plate.
      if (transparentBubble) return null;
      return bubbleContentBackground ?? contentBackground;
    }
    return bubbleOnlyContentBackground ? null : contentBackground;
  }

  /// Inner-element and shop-demo color; differs from the body only for satoshi.
  Color previewColorFor({required bool bubble}) =>
      childColor ?? textColorFor(bubble: bubble);
}

/// Soft radial wash under a watermark's tiles (eclipse's warm glow).
class RadialWash {
  const RadialWash({
    required this.color,
    this.center = Alignment.center,
    this.radius = 0.55,
  });

  /// Center color, fading to transparent at [radius].
  final Color color;

  /// Gradient center, e.g. `circle at 20% 50%` -> `Alignment(-0.6, 0)`.
  final Alignment center;

  /// Transparent stop as a fraction of the box.
  final double radius;
}

/// One text glyph in a tiled watermark at the SVG baseline; flutter_svg drops `<text>`, so these use a TextPainter.
class GlyphTile {
  const GlyphTile(this.text, this.dx, this.baselineY, this.fontSize,
      {this.mono = false});
  final String text;
  final double dx;
  final double baselineY;
  final double fontSize;
  final bool mono;
}

/// Repeating texture: tiled SVG, tiled glyphs (satoshi/matrix), or scanlines (CRT).
class StyleWatermark {
  const StyleWatermark.svg(this.svg, this.size, {this.radialWash})
      : scanline = null,
        scanlineGap = 0,
        scanlineThickness = 0,
        glyphs = null,
        glyphColor = null;

  /// Horizontal scanlines of [scanlineThickness]px every [scanlineGap]px.
  const StyleWatermark.scanlines({
    required Color color,
    required this.scanlineGap,
    required this.scanlineThickness,
  })  : svg = null,
        size = Size.zero,
        scanline = color,
        radialWash = null,
        glyphs = null,
        glyphColor = null;

  /// Tiled text glyphs painted via [TextPainter].
  const StyleWatermark.glyphs(this.glyphs, this.size, this.glyphColor)
      : svg = null,
        scanline = null,
        scanlineGap = 0,
        scanlineThickness = 0,
        radialWash = null;

  final String? svg;
  final Size size;
  final Color? scanline;
  final double scanlineGap;
  final double scanlineThickness;

  /// Tiled glyphs, or null for SVG/scanline variants.
  final List<GlyphTile>? glyphs;
  final Color? glyphColor;

  /// Optional radial wash behind the tiled SVG, or null.
  final RadialWash? radialWash;

  bool get isScanlines => scanline != null;
  bool get isGlyphs => glyphs != null;
}

/// Special cosmetic aura: inset and outer glow, IRC accent bar, gradient and optional watermark.
class CosmeticAura {
  const CosmeticAura({
    required this.id,
    this.insetColor,
    this.bubbleInsetColor,
    this.insetWidth = 1,
    this.glowColor,
    this.glowBlur = 0,
    this.bubbleGlowColor,
    this.bubbleGlowBlur,
    this.borderAccent,
    this.gradient,
    this.bubbleGradient,
    this.bubblePaintsGradient = false,
    this.bubbleStyledFill,
    this.background,
    this.watermark,
    this.edgeWatermark = false,
    this.prismRing = false,
    this.hologram = false,
    this.insetRing = false,
  });

  final String id;

  /// Inset ring painted fully inside the edge by [CosmeticOverlayPainter] when [insetRing] is set.
  final Color? insetColor;

  /// Bubble-layout inset ring color when it differs; null uses [insetColor].
  final Color? bubbleInsetColor;
  final double insetWidth;

  /// Outer glow color (IRC).
  final Color? glowColor;
  final double glowBlur;

  /// Bubble-layout glow color when it differs; null uses [glowColor].
  final Color? bubbleGlowColor;

  /// Bubble-layout glow blur when it differs; null uses [glowBlur].
  final double? bubbleGlowBlur;

  /// 3px left border accent (IRC).
  final Color? borderAccent;

  /// 135° gradient on the IRC row; the bubble fill only when [bubblePaintsGradient] (gold).
  final List<Color>? gradient;

  /// Bubble-fill gradient when it differs; null reuses [gradient].
  final List<Color>? bubbleGradient;

  /// Whether bubbles paint the gradient as their fill (gold only).
  final bool bubblePaintsGradient;

  /// Solid-ui opaque bubble plate for gold on styled messages only; unstyled bubbles keep the glass wash.
  final Color? bubbleStyledFill;

  /// Flat background fill when there's no gradient (frost).
  final Color? background;

  /// Tiled watermark (frost snowflakes, cosmic starfield).
  final StyleWatermark? watermark;

  /// Tile only along the four edges (frost).
  final bool edgeWatermark;

  /// Conic prism ring border (rainbow).
  final bool prismRing;

  /// Holographic multi-gradient sheen.
  final bool hologram;

  /// Paint the inset box-shadow as a true inner ring with a soft feather.
  final bool insetRing;

  /// True when [CosmeticOverlayPainter] should paint this aura.
  bool get hasOverlay => prismRing || hologram || insetRing;

  /// Inset ring color for the layout.
  Color? insetColorFor({required bool bubble}) =>
      bubble ? (bubbleInsetColor ?? insetColor) : insetColor;

  /// Outer glow color for the layout.
  Color? glowColorFor({required bool bubble}) =>
      bubble ? (bubbleGlowColor ?? glowColor) : glowColor;

  /// Outer glow blur for the layout.
  double glowBlurFor({required bool bubble}) =>
      bubble ? (bubbleGlowBlur ?? glowBlur) : glowBlur;

  /// [bubbleGradient] when given, else [gradient].
  List<Color>? get bubbleFillGradient => bubbleGradient ?? gradient;
}

/// Mode-aware decoration for a style id, or null; [isLight] uses darker glow-less colors, [solidUi] opaque plates.
MessageStyleDecoration? messageStyleDecoration(String? styleId,
    {bool isLight = false, bool solidUi = false}) {
  if (styleId == null || styleId.isEmpty) return null;
  final v = ShopCatalog.styleVisuals[styleId];
  if (v == null) return null;
  final lightColor = isLight ? _styleLightColor[styleId] : null;
  final hasLightText = lightColor != null;
  // Satoshi's body is white/brown while its inner children stay orange.
  final bodyColor =
      isLight ? _styleLightBodyColor[styleId] : _styleBodyColor[styleId];
  final innerColor = hasLightText ? lightColor : v.color;
  // Satoshi has no message text-shadow, so no glow is manufactured.
  final hasMessageShadow = _styleGlyphShadows.containsKey(styleId) ||
      _styleGlowShadows.containsKey(styleId);
  return MessageStyleDecoration(
    textColor: bodyColor ?? innerColor,
    // Set only for the satoshi container/child split.
    childColor: bodyColor != null ? innerColor : null,
    // Light mode drops the glow (glitch keeps its split via [glyphShadows]).
    glow: (hasLightText || !hasMessageShadow) ? null : v.glow,
    glowShadows: hasLightText ? null : _styleGlowShadows[styleId],
    // Only aurora keeps a gradient in light mode.
    gradient: isLight ? _styleLightGradient[styleId] : v.gradient,
    // Aurora's gradient glow is dark mode only.
    gradientGlow:
        (!isLight && v.gradient != null) ? _styleGradientGlow[styleId] : null,
    contentBackground: (solidUi
            ? (isLight
                ? _styleSolidLightContentBackground
                : _styleSolidContentBackground)[styleId]
            : null) ??
        (isLight ? _styleLightContentBackground[styleId] : null) ??
        _styleContentBackground[styleId],
    // Bubble background overrides; solid-ui drops them in favor of opaque plates.
    bubbleContentBackground: (isLight && !solidUi)
        ? _styleLightBubbleContentBackground[styleId]
        : null,
    contentPadding: _styleContentPadding[styleId],
    // Aurora keeps the default bubble plate in both modes.
    transparentBubble: styleId == 'style-aurora',
    // Bubble-only fire/ice colors are dark-mode only.
    bubbleTextColor: hasLightText ? null : _styleBubbleTextColor[styleId],
    monospace: v.monospace,
    // Satoshi's bold belongs to inner children, not bare body text.
    bold: _styleBold.contains(styleId) && bodyColor == null,
    glyphShadows: _styleGlyphShadows[styleId],
    watermark: isLight
        ? (_styleLightWatermarks[styleId] ?? styleWatermarks[styleId])
        : styleWatermarks[styleId],
  );
}

/// Per-style text-shadow stacks with real blur radii; glitch uses [_styleGlyphShadows] instead.
const Map<String, List<Shadow>> _styleGlowShadows = {
  'style-neon': [
    Shadow(color: Color(0xFFFF00FF), blurRadius: 10),
    Shadow(color: Color(0xFFFF00FF), blurRadius: 20),
    Shadow(color: Color(0xFFFF00FF), blurRadius: 30),
  ],
  'style-matrix': [
    Shadow(color: Color(0xFF00FF00), blurRadius: 10),
    Shadow(color: Color(0xFF00FF00), blurRadius: 20),
  ],
  'style-ghost': [
    Shadow(color: Color(0x80FFFFFF), offset: Offset(0, 2), blurRadius: 16),
  ],
  'style-fire': [Shadow(color: Color(0xCCFFA000), blurRadius: 14)],
  'style-ice': [Shadow(color: Color(0x8000C8FF), blurRadius: 8)],
  'style-rainbow': [Shadow(color: Color(0x59C77DFF), blurRadius: 8)],
  'style-ocean': [Shadow(color: Color(0x8038BDF8), blurRadius: 8)],
  'style-sakura': [Shadow(color: Color(0x80FF7EB6), blurRadius: 8)],
  'style-galaxy': [Shadow(color: Color(0x99C084FC), blurRadius: 8)],
  'style-toxic': [Shadow(color: Color(0x8084FF3B), blurRadius: 8)],
  'style-gold': [Shadow(color: Color(0x80FFD700), blurRadius: 8)],
  'style-vapor': [
    Shadow(color: Color(0x80FF71CE), blurRadius: 8),
    Shadow(color: Color(0x4D05D9E8), blurRadius: 14),
  ],
  'style-blood': [Shadow(color: Color(0x99FF1E1E), blurRadius: 8)],
  'style-royal': [
    Shadow(color: Color(0x80C4A3FF), blurRadius: 8),
    Shadow(color: Color(0x4DD4AF37), blurRadius: 12),
  ],
  'style-circuit': [Shadow(color: Color(0x802DD4BF), blurRadius: 8)],
  'style-eclipse': [
    Shadow(color: Color(0x8CFFAA5A), blurRadius: 8),
    Shadow(color: Color(0x4DFF783C), blurRadius: 16),
  ],
  'style-crt': [Shadow(color: Color(0xD9FFB000), blurRadius: 8)],
  // satoshi has no text-shadow; absent.
};

/// Aurora's gradient glow, dark mode only.
const Map<String, Shadow> _styleGradientGlow = {
  'style-aurora': Shadow(color: Color(0x4D5B8CFF), blurRadius: 10),
};

/// Brighter bubble-only glyph colors for fire and ice.
const Map<String, Color> _styleBubbleTextColor = {
  'style-fire': Color(0xFFFF6600),
  'style-ice': Color(0xFF00CCFF),
};

/// Styles that bold their glyphs.
const Set<String> _styleBold = {'style-satoshi'};

/// Satoshi's own content padding.
const Map<String, EdgeInsets> _styleContentPadding = {
  'style-satoshi': EdgeInsets.symmetric(horizontal: 15, vertical: 10),
};

/// Dark container body color for split styles (satoshi white).
const Map<String, Color> _styleBodyColor = {
  'style-satoshi': Color(0xFFFFFFFF),
};

/// Light container body color for split styles.
const Map<String, Color> _styleLightBodyColor = {
  'style-satoshi': Color(0xFF7A5500),
};

/// Light-mode text colors; for satoshi this is the inner child color.
const Map<String, Color> _styleLightColor = {
  'style-matrix': Color(0xFF006600),
  'style-neon': Color(0xFF990099),
  'style-ghost': Color(0x73000000),
  'style-fire': Color(0xFFCC4400),
  'style-ice': Color(0xFF006688),
  'style-rainbow': Color(0xFF8A3FD0),
  'style-glitch': Color(0xFF006600),
  'style-satoshi': Color(0xFFC47A15),
  'style-ocean': Color(0xFF005F87),
  'style-sakura': Color(0xFFC01F7A),
  'style-galaxy': Color(0xFF6A2FB0),
  'style-toxic': Color(0xFF3A7A00),
  'style-blood': Color(0xFFB3000F),
  'style-royal': Color(0xFF5A2FB0),
  'style-circuit': Color(0xFF00897B),
  'style-gold': Color(0xFF8A6D00),
  'style-vapor': Color(0xFFA3157C),
};

/// Aurora is the only style that stays a gradient in light mode.
const Map<String, List<Color>> _styleLightGradient = {
  'style-aurora': [
    Color(0xFF007766),
    Color(0xFF334499),
    Color(0xFF880066),
    Color(0xFF007766),
  ],
};

/// Light-mode IRC content backgrounds.
const Map<String, Color> _styleLightContentBackground = {
  'style-satoshi': Color(0x1AC47A15),
};

/// Light-mode bubble content backgrounds (fire/ice use a dedicated black@.08 fill).
const Map<String, Color> _styleLightBubbleContentBackground = {
  'style-satoshi': Color(0x1FF7931A),
  'style-fire': Color(0x14000000),
  'style-ice': Color(0x14000000),
};

/// Solid-ui dark: satoshi's plate goes opaque in both layouts.
const Map<String, Color> _styleSolidContentBackground = {
  'style-satoshi': Color(0xFF4A3A1F),
};

/// Solid-ui light: satoshi `#f3dcb4` in both layouts.
const Map<String, Color> _styleSolidLightContentBackground = {
  'style-satoshi': Color(0xFFF3DCB4),
};

/// Styles whose shadow isn't a single glow, like glitch's red/cyan split.
const Map<String, List<Shadow>> _styleGlyphShadows = {
  'style-glitch': [
    Shadow(color: Color(0xFFFF0000), offset: Offset(-2, 0)),
    Shadow(color: Color(0xFF00FFFF), offset: Offset(2, 0)),
  ],
};

/// In-chat `--style-pattern` watermarks with exact paths, tile sizes and alphas (not the denser preview set).
final Map<String, StyleWatermark> styleWatermarks = {
  // ₿ glyph tile at baseline (0,30), 32px, #f7931a @ .2; ₿ resolves via Noto Sans.
  'style-satoshi': StyleWatermark.glyphs(
    [GlyphTile('₿', 0, 30, 32)],
    const Size(50, 40),
    Color(0x33F7931A),
  ),
  'style-matrix': StyleWatermark.glyphs(
    [
      GlyphTile('10', 3, 13, 12, mono: true),
      GlyphTile('01', 19, 27, 12, mono: true),
      GlyphTile('11', 6, 41, 12, mono: true),
    ],
    const Size(36, 48),
    Color(0x2100FF00),
  ),
  // Dim stars plus eclipse's radial warm wash behind the text.
  'style-eclipse': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
    "<g fill='#ffd9a0' fill-opacity='0.12'><circle cx='14' cy='12' r='0.9'/>"
    "<circle cx='46' cy='30' r='0.7'/><circle cx='26' cy='48' r='0.8'/>"
    "</g></svg>",
    const Size(60, 60),
    radialWash: const RadialWash(
      color: Color(0x24FFBE78),
      center: Alignment(-0.6, 0),
      radius: 0.55,
    ),
  ),
  // Amber scanlines: 1px every 3px.
  'style-crt': const StyleWatermark.scanlines(
    color: Color(0x47FFB000),
    scanlineGap: 3,
    scanlineThickness: 1,
  ),
  'style-fire': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
    "<g fill='#ff6600' fill-opacity='0.12'>"
    "<path d='M11 4C12 7 14.5 8.6 14.5 11.6A3.6 3.6 0 0 1 7.4 11.6C7.4 10 "
    "8.4 9.3 9.2 10.1 8.7 7.8 9.7 5.8 11 4Z'/>"
    "<path d='M32 25C32.8 27.2 34.6 28.4 34.6 30.6A2.7 2.7 0 0 1 29.2 "
    "30.6C29.2 29.4 30 28.9 30.6 29.5 30.2 27.8 30.9 26.3 32 25Z'/>"
    "</g></svg>",
    const Size(46, 46),
  ),
  'style-ice': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='44' height='44'>"
    "<g stroke='#00ccee' stroke-opacity='0.16' stroke-width='1' "
    "stroke-linecap='round'>"
    "<path d='M11 4v14M4 11h14M6 6l10 10M16 6 6 16'/>"
    "<path d='M11 5.5 9.5 7M11 5.5 12.5 7M11 16.5 9.5 15M11 16.5 12.5 "
    "15M5.5 11 7 9.5M5.5 11 7 12.5M16.5 11 15 9.5M16.5 11 15 12.5'/></g>"
    "<g stroke='#00ccee' stroke-opacity='0.1' stroke-width='1' "
    "stroke-linecap='round' transform='translate(28 26)'>"
    "<path d='M5 0v10M0 5h10M1.5 1.5 8.5 8.5M8.5 1.5 1.5 8.5'/></g></svg>",
    const Size(44, 44),
  ),
  'style-ghost': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='52' height='52'>"
    "<g fill='#ffffff' fill-opacity='0.08' fill-rule='evenodd'>"
    "<path d='M13 7c-3.3 0-5.5 2.4-5.5 5.5V19l2.2-1.6L12 19l1-1 1 1 2.3-1.6L18.5 "
    "19v-6.5C18.5 9.4 16.3 7 13 7z M10.5 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 "
    "0 1 0 -1.7 0z M13.8 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 0 1 0 -1.7 0z'/>"
    "<path d='M37 29c-2.6 0-4.5 1.9-4.5 4.5V38l1.8-1.3L36 38l.8-.8.8.8 1.7-1.3L41 "
    "38v-4.5C41 30.9 39.1 29 37 29z M35.1 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 "
    "-1.4 0z M37.7 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 -1.4 0z'/></g></svg>",
    const Size(52, 52),
  ),
  'style-ocean': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'>"
    "<g fill='none' stroke='#38bdf8' stroke-opacity='0.16' stroke-width='1.4'>"
    "<path d='M0 12 Q6 6 12 12 T24 12 T36 12 T48 12'/>"
    "<path d='M0 20 Q6 14 12 20 T24 20 T36 20 T48 20'/></g></svg>",
    const Size(48, 24),
  ),
  'style-sakura': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'>"
    "<g fill='#ff7eb6' fill-opacity='0.14'>"
    "<ellipse cx='12' cy='12' rx='3' ry='1.6' transform='rotate(30 12 12)'/>"
    "<ellipse cx='36' cy='30' rx='3' ry='1.6' transform='rotate(-20 36 30)'/>"
    "<ellipse cx='42' cy='8' rx='2.5' ry='1.3' transform='rotate(60 42 8)'/>"
    "<ellipse cx='8' cy='40' rx='2.5' ry='1.3' transform='rotate(10 8 40)'/>"
    "</g></svg>",
    const Size(50, 50),
  ),
  'style-galaxy': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
    "<g fill='#c084fc' fill-opacity='0.2'><circle cx='10' cy='12' r='1.2'/>"
    "<circle cx='40' cy='8' r='0.9'/><circle cx='52' cy='30' r='1.4'/>"
    "<circle cx='24' cy='40' r='1'/><circle cx='8' cy='48' r='0.8'/>"
    "<circle cx='34' cy='52' r='1.1'/></g>"
    "<g stroke='#c084fc' stroke-opacity='0.18' stroke-width='1' "
    "stroke-linecap='round'><path d='M30 22v5M27.5 24.5h5'/></g></svg>",
    const Size(60, 60),
  ),
  'style-toxic': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
    "<g fill='none' stroke='#84ff3b' stroke-opacity='0.14' stroke-width='1.2'>"
    "<circle cx='12' cy='12' r='3'/><circle cx='36' cy='34' r='3'/></g>"
    "<g fill='#84ff3b' fill-opacity='0.12'><circle cx='12' cy='12' r='1'/>"
    "<circle cx='36' cy='34' r='1'/></g></svg>",
    const Size(48, 48),
  ),
  'style-gold': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
    "<g fill='#ffd700' fill-opacity='0.13'>"
    "<path d='M12 4 13.2 10.8 20 12 13.2 13.2 12 20 10.8 13.2 4 12 10.8 10.8z'/>"
    "<path d='M34 26 34.8 30.2 39 31 34.8 31.8 34 36 33.2 31.8 29 31 33.2 30.2z'/>"
    "</g></svg>",
    const Size(46, 46),
  ),
  'style-vapor': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>"
    "<g fill='none' stroke='#05d9e8' stroke-opacity='0.14' stroke-width='1'>"
    "<path d='M0 0H24V24'/></g></svg>",
    const Size(24, 24),
  ),
  'style-blood': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='44' height='44'>"
    "<g fill='#ff3b3b' fill-opacity='0.12'>"
    "<path d='M11 6c3 4 4.5 6 4.5 8a4.5 4.5 0 0 1-9 0c0-2 1.5-4 4.5-8z'/>"
    "<path d='M33 26c2 2.7 3 4 3 5.3a3 3 0 0 1-6 0c0-1.3 1-2.6 3-5.3z'/>"
    "</g></svg>",
    const Size(44, 44),
  ),
  'style-royal': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
    "<g fill='none' stroke='#e8c860' stroke-opacity='0.16' stroke-width='1'>"
    "<path d='M16 4 22 12 16 20 10 12z'/>"
    "<path d='M0 20 6 28 0 36M32 20 26 28 32 36'/></g></svg>",
    const Size(32, 32),
  ),
  'style-circuit': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
    "<g fill='none' stroke='#2dd4bf' stroke-opacity='0.16' stroke-width='1'>"
    "<path d='M6 6h12v12M18 6h12M30 6v10h12M6 24v12h10M16 36h14v8M30 30h12'/></g>"
    "<g fill='#2dd4bf' fill-opacity='0.22'><circle cx='6' cy='6' r='1.5'/>"
    "<circle cx='42' cy='16' r='1.5'/><circle cx='16' cy='36' r='1.5'/>"
    "<circle cx='42' cy='30' r='1.5'/></g></svg>",
    const Size(48, 48),
  ),
  'style-rainbow': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
    "<g fill='none' stroke-width='1.3' stroke-linecap='round'>"
    "<path d='M6 14a6 6 0 0 1 12 0' stroke='#ff3b3b' stroke-opacity='0.5'/>"
    "<path d='M8.5 14a3.5 3.5 0 0 1 7 0' stroke='#33dd00' stroke-opacity='0.45'/>"
    "<path d='M10.5 14a1.5 1.5 0 0 1 3 0' stroke='#2a5bff' stroke-opacity='0.45'/>"
    "<path d='M27 35a6 6 0 0 1 12 0' stroke='#ff8a00' stroke-opacity='0.5'/>"
    "<path d='M29.5 35a3.5 3.5 0 0 1 7 0' stroke='#00c3ff' stroke-opacity='0.45'/>"
    "<path d='M31.5 35a1.5 1.5 0 0 1 3 0' stroke='#b13bff' stroke-opacity='0.45'/>"
    "</g></svg>",
    const Size(46, 46),
  ),
};

/// Light-mode watermark swaps with darker, stronger fills; absent styles keep their dark SVG.
final Map<String, StyleWatermark> _styleLightWatermarks = {
  'style-ghost': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='52' height='52'>"
    "<g fill='#223044' fill-opacity='0.1' fill-rule='evenodd'>"
    "<path d='M13 7c-3.3 0-5.5 2.4-5.5 5.5V19l2.2-1.6L12 19l1-1 1 1 2.3-1.6L18.5 "
    "19v-6.5C18.5 9.4 16.3 7 13 7z M10.5 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 "
    "0 1 0 -1.7 0z M13.8 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 0 1 0 -1.7 0z'/>"
    "<path d='M37 29c-2.6 0-4.5 1.9-4.5 4.5V38l1.8-1.3L36 38l.8-.8.8.8 1.7-1.3L41 "
    "38v-4.5C41 30.9 39.1 29 37 29z M35.1 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 "
    "-1.4 0z M37.7 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 -1.4 0z'/></g></svg>",
    const Size(52, 52),
  ),
  'style-matrix': StyleWatermark.glyphs(
    [
      GlyphTile('10', 3, 13, 12, mono: true),
      GlyphTile('01', 19, 27, 12, mono: true),
      GlyphTile('11', 6, 41, 12, mono: true),
    ],
    const Size(36, 48),
    Color(0x33006600),
  ),
  'style-ocean': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'>"
    "<g fill='none' stroke='#38a8d8' stroke-opacity='0.3' stroke-width='1.4'>"
    "<path d='M0 12 Q6 6 12 12 T24 12 T36 12 T48 12'/>"
    "<path d='M0 20 Q6 14 12 20 T24 20 T36 20 T48 20'/></g></svg>",
    const Size(48, 24),
  ),
  'style-sakura': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'>"
    "<g fill='#c01f7a' fill-opacity='0.24'>"
    "<ellipse cx='12' cy='12' rx='3' ry='1.6' transform='rotate(30 12 12)'/>"
    "<ellipse cx='36' cy='30' rx='3' ry='1.6' transform='rotate(-20 36 30)'/>"
    "<ellipse cx='42' cy='8' rx='2.5' ry='1.3' transform='rotate(60 42 8)'/>"
    "<ellipse cx='8' cy='40' rx='2.5' ry='1.3' transform='rotate(10 8 40)'/>"
    "</g></svg>",
    const Size(50, 50),
  ),
  'style-galaxy': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
    "<g fill='#6a2fb0' fill-opacity='0.32'><circle cx='10' cy='12' r='1.2'/>"
    "<circle cx='40' cy='8' r='0.9'/><circle cx='52' cy='30' r='1.4'/>"
    "<circle cx='24' cy='40' r='1'/><circle cx='8' cy='48' r='0.8'/>"
    "<circle cx='34' cy='52' r='1.1'/></g>"
    "<g stroke='#6a2fb0' stroke-opacity='0.3' stroke-width='1' "
    "stroke-linecap='round'><path d='M30 22v5M27.5 24.5h5'/></g></svg>",
    const Size(60, 60),
  ),
  'style-toxic': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
    "<g fill='none' stroke='#3a7a00' stroke-opacity='0.3' stroke-width='1.2'>"
    "<circle cx='12' cy='12' r='3'/><circle cx='36' cy='34' r='3'/></g>"
    "<g fill='#3a7a00' fill-opacity='0.24'><circle cx='12' cy='12' r='1'/>"
    "<circle cx='36' cy='34' r='1'/></g></svg>",
    const Size(48, 48),
  ),
  'style-gold': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
    "<g fill='#a07a00' fill-opacity='0.22'>"
    "<path d='M12 4 13.2 10.8 20 12 13.2 13.2 12 20 10.8 13.2 4 12 10.8 10.8z'/>"
    "<path d='M34 26 34.8 30.2 39 31 34.8 31.8 34 36 33.2 31.8 29 31 33.2 30.2z'/>"
    "</g></svg>",
    const Size(46, 46),
  ),
  'style-vapor': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>"
    "<g fill='none' stroke='#b9b3c2' stroke-opacity='0.35' stroke-width='1'>"
    "<path d='M0 0H24V24'/></g></svg>",
    const Size(24, 24),
  ),
  'style-royal': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
    "<g fill='none' stroke='#9a7b1a' stroke-opacity='0.32' stroke-width='1'>"
    "<path d='M16 4 22 12 16 20 10 12z'/>"
    "<path d='M0 20 6 28 0 36M32 20 26 28 32 36'/></g></svg>",
    const Size(32, 32),
  ),
  'style-circuit': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
    "<g fill='none' stroke='#0a7d70' stroke-opacity='0.34' stroke-width='1'>"
    "<path d='M6 6h12v12M18 6h12M30 6v10h12M6 24v12h10M16 36h14v8M30 30h12'/></g>"
    "<g fill='#0a7d70' fill-opacity='0.42'><circle cx='6' cy='6' r='1.5'/>"
    "<circle cx='42' cy='16' r='1.5'/><circle cx='16' cy='36' r='1.5'/>"
    "<circle cx='42' cy='30' r='1.5'/></g></svg>",
    const Size(48, 48),
  ),
};

/// Translucent content backgrounds; unlisted styles paint none.
const Map<String, Color> _styleContentBackground = {
  'style-satoshi': Color(0x33F7931A),
  // The later override wins.
  'style-eclipse': Color(0xB8120E1C),
  // The later override wins.
  'style-crt': Color(0xD10A0802),
};

/// Supporter style: gold glyphs and glow, gold left bar, and a faint gold wash.
const MessageStyleDecoration supporterStyleDecoration = MessageStyleDecoration(
  textColor: Color(0xFFFFD700),
  glowShadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
  glow: Color(0x40FFD700),
  contentBackground: Color(0x1FFFD700),
  // The gold wash is bubble-only; IRC paints only the row gradient and bar.
  bubbleOnlyContentBackground: true,
  backgroundGradient: [Color(0x14FFD700), Color(0x08FFD700)],
  borderAccent: Color(0xFFFFD700),
);

/// Light supporter: darker gold text without glow and lighter washes.
const MessageStyleDecoration supporterStyleDecorationLight =
    MessageStyleDecoration(
  textColor: Color(0xFF8A6D00),
  // Note the 150 green channel, unlike the 140 of the wash rules.
  contentBackground: Color(0x14B49600),
  // Bubble-only, like the dark wash.
  bubbleOnlyContentBackground: true,
  backgroundGradient: [Color(0x0FB48C00), Color(0x05B48C00)],
  borderAccent: Color(0xFFB8960A),
);

/// Solid-ui dark supporter: opaque bubble fill and flat IRC row plate.
const MessageStyleDecoration supporterStyleDecorationSolid =
    MessageStyleDecoration(
  textColor: Color(0xFFFFD700),
  glowShadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
  glow: Color(0x40FFD700),
  contentBackground: Color(0xFF3D3520),
  bubbleOnlyContentBackground: true,
  // Same-stop gradient so the IRC row path renders a flat plate.
  backgroundGradient: [Color(0xFF2A2418), Color(0xFF2A2418)],
  borderAccent: Color(0xFFFFD700),
);

/// Solid-ui light supporter: opaque bubble and flat IRC row plates.
const MessageStyleDecoration supporterStyleDecorationSolidLight =
    MessageStyleDecoration(
  textColor: Color(0xFF8A6D00),
  contentBackground: Color(0xFFEFE2A8),
  bubbleOnlyContentBackground: true,
  backgroundGradient: [Color(0xFFF4EAD0), Color(0xFFF4EAD0)],
  borderAccent: Color(0xFFB8960A),
);

/// Supporter decoration for the mode: [solidUi] opaque plates, [isLight] light palette.
MessageStyleDecoration supporterStyleDecorationFor(
    {required bool isLight, bool solidUi = false}) {
  if (solidUi) {
    return isLight
        ? supporterStyleDecorationSolidLight
        : supporterStyleDecorationSolid;
  }
  return isLight ? supporterStyleDecorationLight : supporterStyleDecoration;
}

/// Styles whose dark color rule is declared after supporter's, so they keep their own text.
const Set<String> _darkStyleColorBeatsSupporter = {
  'style-eclipse',
  'style-crt',
};

/// Styles whose light color rule is declared after supporter's, so they keep their own light color.
const Set<String> _lightStyleColorBeatsSupporter = {
  'style-ocean',
  'style-sakura',
  'style-galaxy',
  'style-toxic',
  'style-blood',
  'style-royal',
  'style-circuit',
  'style-gold',
  'style-vapor',
};

/// Supporter gold composed onto an active style per the CSS cascade; aurora is exempt since its text is gradient-clipped.
MessageStyleDecoration composeSupporterStyle(
  MessageStyleDecoration styled,
  String styleId, {
  required bool isLight,
  bool solidUi = false,
}) {
  if (styleId == 'style-aurora') return styled;
  final supporter =
      supporterStyleDecorationFor(isLight: isLight, solidUi: solidUi);
  final goldText = isLight
      ? !_lightStyleColorBeatsSupporter.contains(styleId)
      : !_darkStyleColorBeatsSupporter.contains(styleId);
  return MessageStyleDecoration(
    textColor: goldText ? supporter.textColor : styled.textColor,
    glow: goldText ? supporter.glow : styled.glow,
    // Supporter's glow replaces the style's stack whenever gold text wins; none in light mode.
    glowShadows: goldText ? supporter.glowShadows : styled.glowShadows,
    glyphShadows: goldText ? null : styled.glyphShadows,
    gradient: styled.gradient,
    gradientGlow: styled.gradientGlow,
    contentBackground: styled.contentBackground,
    bubbleOnlyContentBackground: styled.bubbleOnlyContentBackground,
    // Supporter's bubble wash wins over every style's bubble fill.
    bubbleContentBackground: supporter.contentBackgroundFor(bubble: true),
    contentPadding: styled.contentPadding,
    transparentBubble: styled.transparentBubble,
    backgroundGradient: supporter.backgroundGradient,
    bubbleTextColor: styled.bubbleTextColor,
    childColor: styled.childColor,
    borderAccent: supporter.borderAccent,
    monospace: styled.monospace,
    bold: styled.bold,
    watermark: styled.watermark,
  );
}

/// Active auras in declared order, excluding redacted; only gold has a light override.
List<CosmeticAura> resolveCosmeticAuras(UserCosmetics cosmetics,
    {bool isLight = false, bool solidUi = false}) {
  final out = <CosmeticAura>[];
  for (final id in cosmetics.cosmetics) {
    final aura = cosmeticAuraFor(id, isLight: isLight, solidUi: solidUi);
    if (aura != null) out.add(aura);
  }
  return out;
}

/// Mode-aware aura for [id]; only gold has light and solid-ui overrides.
CosmeticAura? cosmeticAuraFor(String id,
        {bool isLight = false, bool solidUi = false}) =>
    (solidUi
        ? (isLight ? _cosmeticAurasSolidLight : _cosmeticAurasSolid)[id]
        : null) ??
    (isLight ? _cosmeticAurasLight[id] : null) ??
    _cosmeticAuras[id];

const String _frostSnowflakeSvg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'>"
    "<g fill='none' stroke='#68b8e6' stroke-opacity='0.55' stroke-width='1' "
    "stroke-linecap='round'>"
    "<path d='M9 2.5v13M2.5 9h13M4.4 4.4l9.2 9.2M13.6 4.4 4.4 13.6'/>"
    "<path d='M9 4.5 7.5 6M9 4.5 10.5 6M9 13.5 7.5 12M9 13.5 10.5 12M4.5 9 6 "
    "7.5M4.5 9 6 10.5M13.5 9 12 7.5M13.5 9 12 10.5'/></g></svg>";

const String _cosmicStarfieldSvg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
    "<g fill='#cbb8ff'><circle cx='10' cy='12' r='1' fill-opacity='0.5'/>"
    "<circle cx='44' cy='8' r='0.8' fill-opacity='0.4'/>"
    "<circle cx='52' cy='34' r='1.2' fill-opacity='0.55'/>"
    "<circle cx='22' cy='44' r='0.9' fill-opacity='0.45'/>"
    "<circle cx='33' cy='22' r='0.7' fill-opacity='0.4'/>"
    "<circle cx='15' cy='50' r='0.6' fill-opacity='0.35'/></g></svg>";

/// Aura table; `bubble*` fields carry the per-layout differences.
final Map<String, CosmeticAura> _cosmeticAuras = {
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x59FFD700),
    bubbleInsetColor: Color(0x8CFFD700),
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x2EFFD700),
    glowBlur: 18,
    bubbleGlowBlur: 12,
    borderAccent: Color(0xFFFFD700),
    // IRC row gradient .05→.02; bubble fill .16→.06.
    gradient: [Color(0x0DFFD700), Color(0x05FFD700)],
    bubbleGradient: [Color(0x29FFD700), Color(0x0FFFD700)],
    bubblePaintsGradient: true,
  ),
  'cosmetic-aura-neon': const CosmeticAura(
    id: 'cosmetic-aura-neon',
    insetColor: Color(0x8C00E5FF),
    insetRing: true,
    glowColor: Color(0x5200E5FF),
    glowBlur: 22,
    borderAccent: Color(0xFF00E5FF),
    // IRC row gradient only; bubbles are box-shadow only.
    gradient: [Color(0x0F00E5FF), Color(0x0500E5FF)],
  ),
  'cosmetic-aura-rainbow': const CosmeticAura(
    id: 'cosmetic-aura-rainbow',
    glowColor: Color(0x4D9664FF),
    glowBlur: 16,
    prismRing: true,
  ),
  'cosmetic-frost': CosmeticAura(
    id: 'cosmetic-frost',
    insetColor: const Color(0x8CE1F6FF),
    insetRing: true,
    glowColor: const Color(0x3396D2FF),
    glowBlur: 10,
    background: const Color(0x29BEE6FF),
    watermark: StyleWatermark.svg(_frostSnowflakeSvg, const Size(18, 18)),
    edgeWatermark: true, // snowflakes tile along the 4 edges, not full-box
  ),
  'cosmetic-aura-phoenix': const CosmeticAura(
    id: 'cosmetic-aura-phoenix',
    insetColor: Color(0x99FFA000),
    insetRing: true,
    glowColor: Color(0x66FF6E00),
    glowBlur: 26,
    borderAccent: Color(0xFFFF6A00),
    // IRC row gradient only; bubbles paint no fill.
    gradient: [Color(0x12FF6A00), Color(0x08FF0000)],
  ),
  'cosmetic-aura-cosmic': CosmeticAura(
    id: 'cosmetic-aura-cosmic',
    insetColor: const Color(0x99A082FF),
    insetRing: true,
    glowColor: const Color(0x738C64FF),
    glowBlur: 26,
    borderAccent: const Color(0xFF7C5CFF),
    // IRC row gradient only; bubbles get just the starfield.
    gradient: const [Color(0x29462D8C), Color(0x0F0F0C23)],
    watermark: StyleWatermark.svg(_cosmicStarfieldSvg, const Size(60, 60)),
  ),
  'cosmetic-bubble-hologram': const CosmeticAura(
    id: 'cosmetic-bubble-hologram',
    insetColor: Color(0x80FFFFFF),
    insetRing: true,
    glowColor: Color(0x8096B4FF),
    glowBlur: 18,
    hologram: true,
  ),
};

/// Light overrides: only gold has one; others keep their dark values.
final Map<String, CosmeticAura> _cosmeticAurasLight = {
  // IRC: inset .3, glow 12px .12, border #b8960a, bg .06→.02. Bubble: inset .5, glow 10px .15, fill .18→.06.
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x4DB48C00),
    bubbleInsetColor: Color(0x80B48C00),
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x1FB48C00),
    glowBlur: 12,
    bubbleGlowColor: Color(0x26B48C00),
    bubbleGlowBlur: 10,
    borderAccent: Color(0xFFB8960A),
    gradient: [Color(0x0FB48C00), Color(0x05B48C00)],
    bubbleGradient: [Color(0x2EB48C00), Color(0x0FB48C00)],
    bubblePaintsGradient: true,
  ),
};

/// Solid-ui dark overrides: only gold; ring and glow carry over.
final Map<String, CosmeticAura> _cosmeticAurasSolid = {
  // IRC row flattens to an opaque plate; unstyled bubbles keep the glass wash, styled ones get [bubbleStyledFill].
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x59FFD700),
    bubbleInsetColor: Color(0x8CFFD700),
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x2EFFD700),
    glowBlur: 18,
    bubbleGlowBlur: 12,
    borderAccent: Color(0xFFFFD700),
    gradient: [Color(0xFF2A2418), Color(0xFF2A2418)],
    bubbleGradient: [Color(0x29FFD700), Color(0x0FFFD700)],
    bubblePaintsGradient: true,
    bubbleStyledFill: Color(0xFF38311E),
  ),
};

/// Solid-ui light: gold's bubble plate is opaque for all messages; IRC row flattens.
final Map<String, CosmeticAura> _cosmeticAurasSolidLight = {
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x4DB48C00),
    bubbleInsetColor: Color(0x80B48C00),
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x1FB48C00),
    glowBlur: 12,
    bubbleGlowColor: Color(0x26B48C00),
    bubbleGlowBlur: 10,
    borderAccent: Color(0xFFB8960A),
    gradient: [Color(0xFFF4EAD0), Color(0xFFF4EAD0)],
    bubbleGradient: [Color(0xFFF0E3AD), Color(0xFFF0E3AD)],
    bubblePaintsGradient: true,
    bubbleStyledFill: Color(0xFFF0E3AD),
  ),
};

/// Watermark fill widget; the caller wraps it in `Positioned.fill` and clips it.
class StyleWatermarkLayer extends StatelessWidget {
  const StyleWatermarkLayer({
    super.key,
    required this.watermark,
    this.edgeOnly = false,
  });

  final StyleWatermark watermark;

  /// Tile only along the four edges (frost).
  final bool edgeOnly;

  @override
  Widget build(BuildContext context) {
    if (watermark.isScanlines) {
      return IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ScanlinePainter(watermark),
        ),
      );
    }
    // flutter_svg can't render `<text>`, so glyph patterns use a TextPainter.
    if (watermark.isGlyphs) {
      return IgnorePointer(
        child: ClipRect(
          child: CustomPaint(
            size: Size.infinite,
            painter: _GlyphTilePainter(watermark),
          ),
        ),
      );
    }
    // Tiled SVG, optionally over eclipse's radial wash.
    final tiles = edgeOnly
        ? _EdgeTiledSvg(svg: watermark.svg!, tile: watermark.size)
        : _TiledSvg(svg: watermark.svg!, tile: watermark.size);
    final wash = watermark.radialWash;
    return IgnorePointer(
      child: ClipRect(
        child: wash == null
            ? tiles
            : Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: wash.center,
                          radius: wash.radius,
                          colors: [wash.color, wash.color.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                  tiles,
                ],
              ),
      ),
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  _ScanlinePainter(this.w);
  final StyleWatermark w;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = w.scanline!;
    for (var y = 0.0; y < size.height; y += w.scanlineGap) {
      canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, w.scanlineThickness), paint);
    }
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.w != w;
}

/// Tiles text glyphs, shifting each by its ascent so it lands on the SVG baseline.
class _GlyphTilePainter extends CustomPainter {
  _GlyphTilePainter(this.w);
  final StyleWatermark w;

  @override
  void paint(Canvas canvas, Size size) {
    final tile = w.size;
    if (tile.width <= 0 || tile.height <= 0) return;
    // Lay each glyph out once, then stamp it across the grid.
    final painters = <(double, double, TextPainter)>[];
    for (final g in w.glyphs!) {
      final tp = TextPainter(
        text: TextSpan(
          text: g.text,
          style: TextStyle(
            color: w.glyphColor,
            fontSize: g.fontSize,
            fontFamily: g.mono ? kMonoFont : kSansSymFont,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final baseline =
          tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      // SVG `y` is the baseline; TextPainter paints from the glyph top.
      painters.add((g.dx, g.baselineY - baseline, tp));
    }
    for (var y = 0.0; y < size.height; y += tile.height) {
      for (var x = 0.0; x < size.width; x += tile.width) {
        for (final (dx, dy, tp) in painters) {
          tp.paint(canvas, Offset(x + dx, y + dy));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphTilePainter old) => old.w != w;
}

/// Repeats an SVG tile with positioned cells in a Stack, avoiding RenderFlex overflow.
class _TiledSvg extends StatelessWidget {
  const _TiledSvg({required this.svg, required this.tile});
  final String svg;
  final Size tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final h =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 120.0;
        final cols = (w / tile.width).ceil();
        final rows = (h / tile.height).ceil();
        // Tiles from the top-left; the partial edge is clipped by the ClipRect.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var r = 0; r < rows; r++)
              for (var col = 0; col < cols; col++)
                Positioned(
                  left: col * tile.width,
                  top: r * tile.height,
                  width: tile.width,
                  height: tile.height,
                  // A widget can't appear twice in the tree, so each cell gets its own picture.
                  child: SvgPicture.string(
                    svg,
                    width: tile.width,
                    height: tile.height,
                    fit: BoxFit.fill,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// Tiles an SVG only along the four edges, centered, like frost's pattern.
class _EdgeTiledSvg extends StatelessWidget {
  const _EdgeTiledSvg({required this.svg, required this.tile});
  final String svg;
  final Size tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final h =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 120.0;
        final cols = (w / tile.width).ceil() + 1;
        final rows = (h / tile.height).ceil() + 1;
        // Inner vertical strips skip the corner rows already covered.
        final innerRows = rows - 2 > 0 ? rows - 2 : 0;
        final x0 = (w - cols * tile.width) / 2;
        final y0 = (h - innerRows * tile.height) / 2;
        // Each cell gets its own picture.
        Widget cellAt(double left, double top) => Positioned(
              left: left,
              top: top,
              width: tile.width,
              height: tile.height,
              child: SvgPicture.string(
                svg,
                width: tile.width,
                height: tile.height,
                fit: BoxFit.fill,
              ),
            );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var col = 0; col < cols; col++)
              cellAt(x0 + col * tile.width, 0),
            for (var col = 0; col < cols; col++)
              cellAt(x0 + col * tile.width, h - tile.height),
            for (var r = 0; r < innerRows; r++) cellAt(0, y0 + r * tile.height),
            for (var r = 0; r < innerRows; r++)
              cellAt(w - tile.width, y0 + r * tile.height),
          ],
        );
      },
    );
  }
}

/// Paints prism ring, hologram sheen and true inset rings above the content; message_row skips its own border for these.
class CosmeticOverlayPainter extends CustomPainter {
  CosmeticOverlayPainter({
    required this.aura,
    required this.radius,
    this.bubble = true,
    this.styleActive = false,
  });

  final CosmeticAura aura;
  final BorderRadius radius;

  /// Bubble layout selects [CosmeticAura.bubbleInsetColor].
  final bool bubble;

  /// An active style drops the hologram fill and sheen, keeping the ring.
  final bool styleActive;

  static const List<Color> _prism = [
    Color(0xFFFF2D2D),
    Color(0xFFFF8A00),
    Color(0xFFFFE600),
    Color(0xFF33DD00),
    Color(0xFF00C3FF),
    Color(0xFF2A5BFF),
    Color(0xFFB13BFF),
    Color(0xFFFF2D2D),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    if (aura.prismRing) {
      // SweepGradient starts at 3 o'clock, so rotate a quarter turn to put red at the top like CSS conic.
      final shader = const SweepGradient(
        colors: _prism,
        transform: GradientRotation(-math.pi / 2),
      ).createShader(rect);
      final ring = Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawRRect(rrect.deflate(1.5), ring);
    }
    // The hologram fill and sheen drop when a style is active; the ring stays.
    if (aura.hologram && !styleActive) {
      // Only the white sheen screen-blends; the color gradient composites normally.
      final base = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x66FF00C8),
            Color(0x6600C8FF),
            Color(0x6678FFAA),
            Color(0x66FFE100),
            Color(0x66FF00C8),
          ],
        ).createShader(rect);
      canvas.drawRRect(rrect, base);
      final sheen = Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-1, -0.6),
          end: Alignment(1, 0.6),
          colors: [
            Color(0x00FFFFFF),
            Color(0x47FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0.43, 0.5, 0.57],
        ).createShader(rect)
        ..blendMode = BlendMode.screen;
      canvas.drawRRect(rrect, sheen);
    }
    // Drawn last so it sits crisply on top.
    final ringColor = aura.insetColorFor(bubble: bubble);
    if (aura.insetRing && ringColor != null) {
      final w = aura.insetWidth;
      // Deflated by half the width so the stroke stays inside the edge, like CSS inset.
      final ringRect = rrect.deflate(w / 2);
      final ring = Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = w;
      canvas.drawRRect(ringRect, ring);
      // Faint inward feather at a low fixed alpha, clipped to the bubble.
      final inner = rrect.deflate(w);
      final feather = Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [
            ringColor.withValues(alpha: 0),
            ringColor.withValues(alpha: 0.10),
          ],
          stops: const [0.72, 1.0],
        ).createShader(inner.outerRect);
      canvas.save();
      canvas.clipRRect(inner);
      canvas.drawRRect(inner, feather);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CosmeticOverlayPainter old) =>
      old.aura.id != aura.id ||
      old.radius != radius ||
      old.bubble != bubble ||
      old.styleActive != styleActive ||
      old.aura.insetColor != aura.insetColor ||
      old.aura.bubbleInsetColor != aura.bubbleInsetColor ||
      old.aura.insetWidth != aura.insetWidth ||
      old.aura.insetRing != aura.insetRing;
}

import 'dart:async';
import 'dart:math' as math;

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

/// The resolved flair-shop cosmetics that should decorate a user's messages and
/// nym, gathered from the right source for the pubkey:
///
/// * For the SELF pubkey we read the live [shopControllerProvider] active state
///   (the same `{style, flair, supporter}` the PWA's `getUserShopItems` returns
///   for `this.pubkey`).
/// * For everyone else we read the [User] fields populated from presence /
///   shop-status ingestion (`shopStyle`, `shopFlair`, `isSupporter`).
///
/// Mirrors `js/modules/shop.js` `getUserShopItems(pubkey)`.
class UserCosmetics {
  const UserCosmetics({
    this.styleId,
    this.flairIds = const [],
    this.supporter = false,
    this.cosmetics = const [],
    this.genesisEdition,
  });

  /// Active message-style item id (e.g. `style-satoshi`), or null.
  final String? styleId;

  /// Active nickname-flair item ids (e.g. `flair-crown`), in record order. The
  /// PWA renders a badge for EVERY id in a user's flair array (`getFlairForUser`
  /// maps each id, shop.js:1149-1154; `_applyFlairBadgesToMessage` forEach,
  /// :520-527) — the SELF activation UI merely caps the local set to one
  /// (shop.js:401), so multi-flair records only arrive for other users.
  final List<String> flairIds;

  /// The last active flair id, or null — for the single-badge surfaces that
  /// only show one (autocomplete rows, poll cards).
  String? get flairId => flairIds.isNotEmpty ? flairIds.last : null;

  /// True when the user owns + has the supporter badge active.
  final bool supporter;

  /// Active special-cosmetic ids (`cosmetic-aura-gold`, `cosmetic-frost`,
  /// `cosmetic-bubble-hologram`, `cosmetic-redacted`, …). Composed onto the
  /// message bubble/row alongside the style. (`shop.js:485-509`.)
  final List<String> cosmetics;

  /// Genesis edition number stamped on the `flair-genesis` badge, if known.
  final int? genesisEdition;

  bool get isEmpty =>
      styleId == null && flairIds.isEmpty && !supporter && cosmetics.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// True when the redacted privacy cosmetic is active (blanks content + author
  /// after a delay — `shop.js:498-503`).
  bool get isRedacted => cosmetics.contains('cosmetic-redacted');

  static const UserCosmetics none = UserCosmetics();
}

/// Resolves the [UserCosmetics] for [pubkey]. Reads `shopControllerProvider` for
/// the self pubkey; for others it prefers the authoritative D1 `shop-status`
/// record ([otherUsersShopProvider]) and falls back to the presence-broadcast
/// `usersProvider` fields. Pure with respect to its inputs (no fetch), so it can
/// be called from `build`. Mirrors `getUserShopItems(pubkey)` (shop.js:1111).
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

/// Builds [UserCosmetics] from the self pubkey's live shop [active] state
/// (`getUserShopItems(this.pubkey)`), including the cosmetics array + Genesis
/// edition number.
UserCosmetics _selfCosmetics(ActiveItems active) {
  return UserCosmetics(
    styleId: active.style,
    // The PWA caps the SELF flair set to the last activated id (shop.js:401).
    flairIds: active.flair.isNotEmpty ? [active.flair.last] : const [],
    supporter: active.supporter,
    cosmetics: active.cosmetics,
    genesisEdition: active.editions['flair-genesis'],
  );
}

/// Builds [UserCosmetics] from a [User]'s presence-broadcast cosmetic fields.
/// Exposed for tests and for the `watch`-based [userCosmeticsProvider].
UserCosmetics userCosmeticsFromUser(User? user) {
  if (user == null) return UserCosmetics.none;
  return UserCosmetics(
    styleId: (user.shopStyle != null && user.shopStyle!.isNotEmpty)
        ? user.shopStyle
        : null,
    // Presence broadcasts carry a single flair field.
    flairIds: (user.shopFlair != null && user.shopFlair!.isNotEmpty)
        ? [user.shopFlair!]
        : const [],
    supporter: user.isSupporter,
    cosmetics: user.shopCosmetics,
    genesisEdition: user.shopEdition,
  );
}

/// Builds [UserCosmetics] from a D1 `shop-status` active record — the
/// authoritative source for other users' cosmetics (shop.js:459-467). Keeps the
/// FULL flair array (the PWA renders a badge per id, shop.js:520-527/1149-1154)
/// and surfaces the Genesis edition from `active.editions`.
UserCosmetics userCosmeticsFromStatus(ShopStatusActive a) {
  return UserCosmetics(
    styleId: (a.style != null && a.style!.isNotEmpty) ? a.style : null,
    flairIds: a.flair,
    supporter: a.supporter,
    cosmetics: a.cosmetics,
    genesisEdition: a.editions['flair-genesis'],
  );
}

/// Family provider variant of [resolveCosmetics], so widgets can `watch` a
/// pubkey's cosmetics and rebuild when the self shop state, the authoritative
/// D1 `shop-status` cache, or the user's presence-broadcast cosmetics change.
///
/// For a non-self pubkey this also QUEUES a batched `shop-status` D1 fetch
/// (debounced, deduped, 10-min-fresh) the first time the pubkey is seen with no
/// cached record — mirroring the PWA's `getUserShopItems` → `_queueShopStatusFetch`
/// (shop.js:1121). The queue runs on a microtask so the provider body stays
/// side-effect-free during build; the cache update then rebuilds this provider.
final userCosmeticsProvider =
    Provider.family<UserCosmetics, String>((ref, pubkey) {
  final selfPubkey = ref.watch(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    return _selfCosmetics(ref.watch(shopControllerProvider).active);
  }
  final key = pubkey.toLowerCase();
  final fromD1 = ref.watch(otherUsersShopProvider)[key];
  if (fromD1 != null) return userCosmeticsFromStatus(fromD1);
  // Unknown to D1 yet: trigger a batched lookup, then fall back to the
  // presence-broadcast fields until the record lands.
  final other = ref.read(otherUsersShopProvider.notifier);
  scheduleMicrotask(() => other.queue(key));
  final user = ref.watch(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
});

/// The inline flair + supporter badges that follow a nym wherever it is
/// rendered (after the `#suffix`, before any friend badge — mirroring
/// `_applyFlairBadgesToMessage`). Reuses the shop's [FlairBadge] /
/// [SupporterBadge] widgets so the glyphs/colours/gradient match the shop 1:1.
///
/// Renders nothing when the user has no active flair and is not a supporter.
class CosmeticNymBadges extends StatelessWidget {
  const CosmeticNymBadges({
    super.key,
    required this.cosmetics,
    this.edition,
    // `.flair-badge { font-size: 20px }` — the PWA-exact glyph size on every nym
    // (styles-features.css:316-320). (Was 16, an under-sized substitute.)
    this.flairSize = 20,
    this.supporterHeight = 18,
  });

  final UserCosmetics cosmetics;

  /// Genesis edition number to stamp on a numbered flair, if known.
  final int? edition;

  final double flairSize;
  final double supporterHeight;

  @override
  Widget build(BuildContext context) {
    // One badge per ACTIVE flair id, in record order, skipping ids the catalog
    // doesn't know (`_applyFlairBadgesToMessage` forEach + its
    // `getShopItemById(id)` guard, shop.js:520-527).
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
            // Stamp the Genesis edition number on the genesis badge when an
            // explicit edition wasn't passed (`_flairIconHtml(id, editions[id])`
            // — only genesis renders its number).
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

/// True when [cosmetics] should bold the whole author nym — the Genesis holder
/// treatment (`.has-genesis-flair { font-weight: 700 }`, the suffix stays 400).
bool hasGenesisFlair(UserCosmetics cosmetics) =>
    cosmetics.flairIds.contains('flair-genesis');

/// A faithful Flutter translation of a `.message.style-X` rule from
/// `css/styles-features.css`. Captures the parts we can render natively:
///
/// * [textColor] — the glyph colour (`.message-content { color }`).
/// * [glow] — the text-shadow glow colour, rendered as a [Shadow] on the
///   content GLYPHS only (via [textShadows]). The CSS style glow is a
///   `text-shadow` — no style paints a `.message-content` box-shadow in either
///   theme, so this must never be drawn as a bubble/box shadow (doing so bled
///   the high-alpha glow through the translucent dark bubble as an opaque
///   wash + oversized halo).
/// * [gradient] — for gradient-text styles (aurora), drawn via a `ShaderMask`.
/// * [contentBackground] — the translucent `.message-content { background-color }`
///   some styles paint behind the text (satoshi / ocean / eclipse / crt / …).
/// * [borderAccent] — a left accent bar painted in IRC layout (supporter-style).
/// * [monospace] — CRT renders in a monospace family.
///
/// The per-glyph repeating SVG watermarks (`--style-pattern`) and the animated
/// effects (prism rotation, glitch offset shadows) are intentionally omitted —
/// see TODO(verify) notes in the task report.
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

  /// The full multi-layer CSS `text-shadow` stack (each layer with its own
  /// colour + blur radius), e.g. neon's `0 0 10/20/30px #ff00ff` or vapor's
  /// pink+cyan dual glow. When present this is the source of [textShadows];
  /// [glow] is only a single-layer fallback for styles without an explicit stack.
  final List<Shadow>? glowShadows;

  final List<Color>? gradient;

  /// The blue `text-shadow 0 0 10px rgba(91,140,255,.3)` glow painted behind the
  /// aurora gradient text (the ShaderMask branch is otherwise shadow-less).
  final Shadow? gradientGlow;

  final Color? contentBackground;

  /// The bubble-layout `.message-content { background }` when it differs from
  /// the IRC [contentBackground] (`body.chat-bubbles .message.style-X
  /// .message-content { background: … !important }`): light-mode satoshi paints
  /// `rgba(247,147,26,.12)` in bubbles but the IRC `rgba(196,122,21,.1)` tint.
  /// Null = [contentBackground] in both layouts.
  final Color? bubbleContentBackground;

  /// True when [contentBackground] is a BUBBLE-layout-only wash: supporter's
  /// gold `.message-content` fill is `body.chat-bubbles`-gated
  /// (styles-features.css:3692-3694), so the IRC layout paints NO content plate
  /// for it (supporter's IRC treatment is the row [backgroundGradient] + left
  /// bar alone) — [contentBackgroundFor] `(bubble: false)` returns null.
  final bool bubbleOnlyContentBackground;

  /// The `.message-content` padding a style adds over the layout default — only
  /// satoshi (`.message.style-satoshi .message-content { padding: 10px 15px }`,
  /// styles-features.css:548-549). Applied in BOTH layouts: the rule's
  /// specificity (0,3,0) beats the chat-bubbles padding rule (0,2,1,
  /// styles-features.css:3607), so a satoshi bubble is padded 10/15 too —
  /// message_row.dart and the shop preview both prefer it over the layout
  /// default.
  final EdgeInsets? contentPadding;

  /// True when the bubble layout REPLACES the default translucent bubble fill
  /// with a fully transparent one — aurora (`body.chat-bubbles .message.
  /// style-aurora .message-content` clips its gradient to the text over a
  /// `linear-gradient(transparent, transparent)` border-box layer `!important`,
  /// styles-features.css:3675-3686), so the bubble shape disappears.
  final bool transparentBubble;

  /// A 135deg background gradient painted on the IRC row (`body:not(.chat-bubbles)
  /// .message.X { background: linear-gradient(135deg,…) }`) — supporter's gold
  /// `.08`→`.03` wash. The bubble layout uses the flat [contentBackground]
  /// instead (the bubble override is a solid colour). Null = use [contentBackground].
  final List<Color>? backgroundGradient;

  /// A bubble-layout-only text colour override (`body.chat-bubbles .message.
  /// style-X .message-content { color }`): fire→`#ff6600`, ice→`#00ccff`. IRC
  /// keeps [textColor]. Null = same colour in both layouts.
  final Color? bubbleTextColor;

  /// The `.message-content > *` INNER-element colour, when it differs from the
  /// bare-body [textColor] (the container/child split). Only satoshi splits: the
  /// `.message-content` container — and so the bare body text — is white
  /// (`#FFFFFF` dark / `#7a5500` light, styles-features.css:550 / themes:900),
  /// while the inner `> *` children (links/mentions/emoji) are the bold orange
  /// `#f7931a`/`#c47a15` (`:571` / themes:905). The shop DEMO wraps its sample in
  /// a `<span>` (a child), so previews use this colour; real plain message text
  /// is bare nodes, so the body uses [textColor]. Null = children share [textColor].
  final Color? childColor;

  final Color? borderAccent;
  final bool monospace;

  /// Bold the styled glyphs (`font-weight: bold`) — satoshi.
  final bool bold;

  /// Explicit glyph shadows that override the default blurred [glow] — used for
  /// the glitch style's red/-2px + cyan/+2px chromatic split (`.style-glitch`).
  final List<Shadow>? glyphShadows;

  /// The repeating-SVG / scanline texture painted behind the content
  /// (`--style-pattern` / `.message-content::before`), or null.
  final StyleWatermark? watermark;

  /// The glyph [Shadow]s reproducing the CSS `text-shadow` glow. Glitch supplies
  /// its own [glyphShadows]; otherwise the full layered [glowShadows] stack, or a
  /// single soft blurred glow as a last resort.
  List<Shadow>? get textShadows {
    if (glyphShadows != null) return glyphShadows;
    if (glowShadows != null) return glowShadows;
    return glow != null ? [Shadow(color: glow!, blurRadius: 10)] : null;
  }

  /// The body text colour for [bubble] layout (the bubble override when set).
  /// This is the `.message-content` CONTAINER colour — what bare body text uses.
  Color textColorFor({required bool bubble}) =>
      bubble ? (bubbleTextColor ?? textColor) : textColor;

  /// The `.message-content` background for the layout: the bubble override /
  /// transparent-bubble replacement in bubble mode, else [contentBackground].
  /// A NON-null return replaces the layout's default translucent bubble fill
  /// (aurora returns fully transparent); null = keep the default fill.
  Color? contentBackgroundFor({required bool bubble}) {
    if (bubble) {
      if (transparentBubble) return const Color(0x00000000);
      return bubbleContentBackground ?? contentBackground;
    }
    return bubbleOnlyContentBackground ? null : contentBackground;
  }

  /// The colour for an INNER `> *` element (link/mention/emoji) and for the shop
  /// DEMO sample (which the PWA wraps in a `<span>`, so it is a child). Falls back
  /// to the body colour for every style except the satoshi container/child split.
  Color previewColorFor({required bool bubble}) =>
      childColor ?? textColorFor(bubble: bubble);
}

/// A soft radial-gradient wash painted UNDER a watermark's tiles (the
/// `radial-gradient(circle at {center}, {color}, transparent {radius})` half of
/// a multi-layer `--style-pattern` — eclipse's warm orange glow behind the text).
class RadialWash {
  const RadialWash({
    required this.color,
    this.center = Alignment.center,
    this.radius = 0.55,
  });

  /// The inner (centre) colour; fades to transparent at [radius].
  final Color color;

  /// The gradient centre (CSS `circle at 20% 50%` → `Alignment(-0.6, 0)`).
  final Alignment center;

  /// The transparent stop as a fraction of the box (`transparent 55%` → 0.55).
  final double radius;
}

/// One glyph in a tiled TEXT watermark: [text] painted at the SVG baseline
/// (`x`=[dx], `y`=[baselineY]) at [fontSize], monospace when [mono]. Used by the
/// satoshi (₿) and matrix (10·01·11) patterns — flutter_svg's vector_graphics
/// backend silently drops `<svg><text>`, so those two `--style-pattern`s are
/// painted with a [TextPainter] tile instead (the path-based patterns stay SVG).
class GlyphTile {
  const GlyphTile(this.text, this.dx, this.baselineY, this.fontSize,
      {this.mono = false});
  final String text;
  final double dx;
  final double baselineY;
  final double fontSize;
  final bool mono;
}

/// A repeating texture painted behind a styled message's content. Either a tiled
/// inline SVG (`svg` + the tile [size]), a tiled [glyphs] TextPainter (satoshi /
/// matrix, whose `<text>` flutter_svg can't render), or a programmatic scanline
/// painter ([scanlines] = CRT/eclipse). Mirrors `--style-pattern`.
class StyleWatermark {
  const StyleWatermark.svg(this.svg, this.size, {this.radialWash})
      : scanline = null,
        scanlineGap = 0,
        scanlineThickness = 0,
        glyphs = null,
        glyphColor = null;

  /// A repeating horizontal scanline (CRT): [scanline]-coloured lines of
  /// [scanlineThickness]px every [scanlineGap]px.
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

  /// A tiled TEXT pattern (satoshi/matrix): [glyphs] painted in [glyphColor]
  /// across a [size] tile via [TextPainter] (flutter_svg drops `<text>`).
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

  /// The tiled-text glyphs (satoshi/matrix) + their colour, or null for the
  /// SVG/scanline variants.
  final List<GlyphTile>? glyphs;
  final Color? glyphColor;

  /// An optional soft radial-gradient wash painted BEHIND the tiled SVG (the
  /// radial half of eclipse's `--style-pattern`), or null.
  final RadialWash? radialWash;

  bool get isScanlines => scanline != null;
  bool get isGlyphs => glyphs != null;
}

/// A resolved special-cosmetic aura composed onto a message bubble/row
/// (`.message.cosmetic-X`). Captures the parts we can render natively: an inset
/// + outer glow box-shadow, a left accent bar (IRC), a background gradient, and
/// an optional tiled watermark. (`styles-features.css:1099-1211`.)
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

  /// `box-shadow: inset 0 0 0 {insetWidth}px {insetColor}`. Rendered as a true
  /// inner ring (stroked fully INSIDE the bubble edge — not an outset glow) by
  /// [CosmeticOverlayPainter] when [insetRing] is set (which, via [hasOverlay],
  /// is the path `message_row` takes for every inset-ring aura). See the
  /// CROSS-FILE NOTE on [CosmeticOverlayPainter] re: the redundant `Border.all`
  /// `message_row` should drop so the ring isn't drawn twice.
  final Color? insetColor;

  /// The bubble-layout inset ring colour when it differs from the IRC [insetColor]
  /// (`body.chat-bubbles .message.cosmetic-aura-gold .message-content` strokes a
  /// `.55` ring vs the IRC `.35`). Null = use [insetColor] in both layouts.
  final Color? bubbleInsetColor;
  final double insetWidth;

  /// `box-shadow: 0 0 {glowBlur}px {glowColor}` (IRC).
  final Color? glowColor;
  final double glowBlur;

  /// The bubble-layout outer-glow COLOUR when it differs from the IRC
  /// [glowColor] — light gold strokes `rgba(180,140,0,.15)` on the bubble
  /// (`body.light-mode.chat-bubbles … .message-content`,
  /// styles-themes-responsive.css:929-932) vs the IRC `.12`. Null = use
  /// [glowColor] in both layouts.
  final Color? bubbleGlowColor;

  /// The bubble-layout outer-glow blur when it differs from the IRC [glowBlur]
  /// (gold: bubble 12px vs IRC 18px). Null = use [glowBlur] in both layouts.
  final double? bubbleGlowBlur;

  /// `border-left: 3px solid …` (IRC).
  final Color? borderAccent;

  /// 135deg background gradient. Painted on the IRC ROW for every aura that has
  /// one (gold/neon/phoenix/cosmic). In the BUBBLE it is painted as the bubble
  /// fill ONLY when [bubblePaintsGradient] is set (gold), because the PWA bubble
  /// for neon/phoenix/cosmic is box-shadow-only (the gradient is IRC-only there).
  final List<Color>? gradient;

  /// The bubble-fill gradient when it differs from the IRC [gradient] (gold's
  /// bubble wash is `.16`→`.06` vs the IRC `.05`→`.02`). Only consulted when
  /// [bubblePaintsGradient]; null = reuse [gradient].
  final List<Color>? bubbleGradient;

  /// True when the BUBBLE layout paints [gradient]/[bubbleGradient] as the bubble
  /// fill. gold=true (PWA bubble gold has a gold wash); neon/phoenix/cosmic=false
  /// (PWA bubble is box-shadow-only — the gradient is the IRC row's only).
  final bool bubblePaintsGradient;

  /// solid-ui only: the opaque bubble plate this aura paints on a message that
  /// ALSO carries a `style-…` class. `body.solid-ui.chat-bubbles .message.
  /// cosmetic-aura-gold .message-content { background: #38311e !important }`
  /// (styles-themes-responsive.css:1740) has no `:not([class*="style-"])` gate
  /// and outcascades every solid style plate (same/lower specificity, declared
  /// earlier); on an UNSTYLED message the last-loaded features-sheet glass wash
  /// (`body.chat-bubbles .message:not([class*="style-"]).cosmetic-aura-gold …
  /// !important`, styles-features.css:3700, equal specificity 0,5,1) wins in
  /// DARK mode, so [bubbleGradient] carries that instead. Null for glass mode
  /// and non-gold auras. Consumed by `message_row`'s bubble-fill resolution.
  final Color? bubbleStyledFill;

  /// A flat background fill (frost icy wash) when there's no gradient.
  final Color? background;

  /// A tiled SVG watermark (frost snowflakes / cosmic starfield).
  final StyleWatermark? watermark;

  /// Tile [watermark] only along the four EDGES (a frosted border) rather than
  /// across the whole content box — frost (`background-position: center top,
  /// center bottom, left center, right center` + `repeat-x/repeat-y`, :1161).
  final bool edgeWatermark;

  /// Render the conic prism ring border (rainbow). Painted via a sweep gradient.
  final bool prismRing;

  /// Render the holographic multi-gradient sheen (hologram).
  final bool hologram;

  /// Render the `inset 0 0 0 {insetWidth}px {insetColor}` box-shadow as a true
  /// inner ring (+ a soft inward feather) via [CosmeticOverlayPainter]. Set for
  /// the aura ids whose CSS box-shadow has an `inset` part
  /// (gold/neon/phoenix/cosmic/frost/hologram). All of these reach the painter
  /// today (via [hasOverlay]); see the CROSS-FILE NOTE on
  /// [CosmeticOverlayPainter] for the `message_row` `Border.all` that must be
  /// suppressed to avoid a double ring.
  final bool insetRing;

  /// True when this aura should be painted by [CosmeticOverlayPainter] (it has a
  /// prism ring, holographic sheen, or a true inset ring to stroke).
  bool get hasOverlay => prismRing || hologram || insetRing;

  /// The inset ring colour for [bubble] layout (the bubble override when set).
  Color? insetColorFor({required bool bubble}) =>
      bubble ? (bubbleInsetColor ?? insetColor) : insetColor;

  /// The outer-glow colour for [bubble] layout (the bubble override when set).
  Color? glowColorFor({required bool bubble}) =>
      bubble ? (bubbleGlowColor ?? glowColor) : glowColor;

  /// The outer-glow blur for [bubble] layout (the bubble override when set).
  double glowBlurFor({required bool bubble}) =>
      bubble ? (bubbleGlowBlur ?? glowBlur) : glowBlur;

  /// The bubble-fill gradient: [bubbleGradient] when given, else [gradient].
  List<Color>? get bubbleFillGradient => bubbleGradient ?? gradient;
}

/// Maps a message-style id to its [MessageStyleDecoration], or null for an
/// unknown id (or null). Pure. Sourced from the per-style `styleVisuals` table
/// (`shop_catalog.dart`, ported from `css/styles-features.css`).
///
/// [isLight] selects the `body.light-mode .message.style-X .message-content`
/// override: the bright dark-mode neons are unreadable on a light bubble, so the
/// PWA swaps to a darker tone and drops the glow (`text-shadow: none`). Styles
/// with no light override (eclipse/crt only restyle the background) keep their
/// dark text/glow.
///
/// [solidUi] applies the `body.solid-ui` overrides (Transparency OFF, the
/// default): satoshi's translucent orange plate becomes the opaque `#4a3a1f` /
/// `#f3dcb4` in BOTH layouts (styles-themes-responsive.css:1714 bubble / 1750
/// IRC, light :1738/:1764), and the light fire/ice `rgba(0,0,0,.08)` bubble fill
/// is dropped so those bubbles fall back to the solid base plate (`body.solid-ui
/// [.light-mode].chat-bubbles .message.style-fire/.style-ice/.style-rainbow
/// .message-content { background: #2a2a3a / #e6e6e0 !important }`, :1702/:1723 —
/// higher specificity than the features-sheet fire/ice fills). Eclipse/crt keep
/// their own translucent plates (the solid block never targets them, and their
/// last-loaded features rules outcascade the solid base fill).
MessageStyleDecoration? messageStyleDecoration(String? styleId,
    {bool isLight = false, bool solidUi = false}) {
  if (styleId == null || styleId.isEmpty) return null;
  final v = ShopCatalog.styleVisuals[styleId];
  if (v == null) return null;
  final lightColor = isLight ? _styleLightColor[styleId] : null;
  final hasLightText = lightColor != null;
  // The `.message-content` CONTAINER (bare body text) colour, for the styles
  // whose body differs from their inner `> *` child colour. Only satoshi: the
  // body is white (#FFFFFF dark / #7a5500 light) while the children stay the bold
  // orange #f7931a/#c47a15. When set, the body uses this and [childColor] carries
  // the orange for inner elements + the shop preview; otherwise body == inner.
  final bodyColor =
      isLight ? _styleLightBodyColor[styleId] : _styleBodyColor[styleId];
  // The inner `> *` / preview colour: the light override when present, else the
  // dark `styleVisuals` colour.
  final innerColor = hasLightText ? lightColor : v.color;
  // satoshi is the one textured style with no `.message-content` text-shadow at
  // all (its glow is preview-only) — so it has neither a glyph-shadow nor a glow
  // layer here, and the single-glow [glow] fallback must NOT manufacture one.
  final hasMessageShadow = _styleGlyphShadows.containsKey(styleId) ||
      _styleGlowShadows.containsKey(styleId);
  return MessageStyleDecoration(
    // Body text uses the CONTAINER colour (white/brown for satoshi); every other
    // style's container IS its inner colour, so this is just [innerColor].
    textColor: bodyColor ?? innerColor,
    // The inner `> *` element + shop-preview colour, set only when it differs
    // from the body (the satoshi split). Null = children inherit [textColor].
    childColor: bodyColor != null ? innerColor : null,
    // Light mode resets `text-shadow` to none — except glitch, whose light rule
    // leaves its red/cyan chromatic split (supplied via [glyphShadows]) intact.
    // Styles with no real message text-shadow (satoshi) drop the glow entirely.
    glow: (hasLightText || !hasMessageShadow) ? null : v.glow,
    // The full multi-layer CSS text-shadow stack (real per-layer blurs), dropped
    // in light mode alongside the single-layer [glow].
    glowShadows: hasLightText ? null : _styleGlowShadows[styleId],
    // Only aurora keeps a multi-stop gradient in light mode; every other gradient
    // style falls back to a solid [_styleLightColor].
    gradient: isLight ? _styleLightGradient[styleId] : v.gradient,
    // The aurora gradient's blue glow (`text-shadow 0 0 10px rgba(91,140,255,.3)`)
    // — dark mode only: the light rule swaps the gradient stops AND resets
    // `text-shadow: none` (styles-themes-responsive.css:884-897).
    gradientGlow:
        (!isLight && v.gradient != null) ? _styleGradientGlow[styleId] : null,
    contentBackground: (solidUi
            ? (isLight
                ? _styleSolidLightContentBackground
                : _styleSolidContentBackground)[styleId]
            : null) ??
        (isLight ? _styleLightContentBackground[styleId] : null) ??
        _styleContentBackground[styleId],
    // Bubble-layout background override — light satoshi's rgba(247,147,26,.12)
    // (styles-themes-responsive.css:1417) vs its IRC rgba(196,122,21,.1) tint.
    // solid-ui drops these: satoshi's opaque plate above covers both layouts,
    // and fire/ice fall back to the solid base bubble fill (themes:1723-1727).
    bubbleContentBackground: (isLight && !solidUi)
        ? _styleLightBubbleContentBackground[styleId]
        : null,
    // satoshi's own `.message-content` padding (`padding: 10px 15px`, :548).
    contentPadding: _styleContentPadding[styleId],
    // Aurora replaces the bubble fill with a transparent border-box layer in
    // BOTH modes (styles-features.css:3675-3686 + themes:843's light gradient).
    transparentBubble: styleId == 'style-aurora',
    // Bubble-only colour overrides (fire/ice). Light mode uses the single light
    // colour for both layouts (the bubble override is a dark-mode-only rule).
    bubbleTextColor: hasLightText ? null : _styleBubbleTextColor[styleId],
    monospace: v.monospace,
    // satoshi's `font-weight: bold` lives on the inner `> *` children
    // (styles-features.css:572), NOT the `.message-content` container — so bare
    // body text is NORMAL weight. When the style splits (bodyColor set), the bold
    // belongs to the children, not the body, so drop it here.
    bold: _styleBold.contains(styleId) && bodyColor == null,
    glyphShadows: _styleGlyphShadows[styleId],
    watermark: isLight
        ? (_styleLightWatermarks[styleId] ?? styleWatermarks[styleId])
        : styleWatermarks[styleId],
  );
}

/// The full per-style CSS `text-shadow` stack, each layer carrying its real
/// colour + blur radius (`.message.style-X .message-content { text-shadow }`,
/// `styles-features.css`). This replaces the uniform 10px single-glow: most
/// styles are 8px, fire 14px, neon a 10/20/30px triple, matrix a 10/20px double,
/// eclipse 8+16px, vapor/royal dual-colour. Styles whose look is a chromatic
/// split (glitch) supply [_styleGlyphShadows] instead and are absent here.
const Map<String, List<Shadow>> _styleGlowShadows = {
  // neon: 0 0 10px, 20px, 30px #ff00ff (triple) (:596-599).
  'style-neon': [
    Shadow(color: Color(0xFFFF00FF), blurRadius: 10),
    Shadow(color: Color(0xFFFF00FF), blurRadius: 20),
    Shadow(color: Color(0xFFFF00FF), blurRadius: 30),
  ],
  // matrix: 0 0 10px, 20px #00ff00 (double) (:590-593).
  'style-matrix': [
    Shadow(color: Color(0xFF00FF00), blurRadius: 10),
    Shadow(color: Color(0xFF00FF00), blurRadius: 20),
  ],
  // ghost: 0 2px 16px rgba(255,255,255,.5) (Y-offset 2, blur 16) (:601-605).
  'style-ghost': [
    Shadow(color: Color(0x80FFFFFF), offset: Offset(0, 2), blurRadius: 16),
  ],
  // fire: 0 0 14px rgba(255,160,0,.8) (:607-610).
  'style-fire': [Shadow(color: Color(0xCCFFA000), blurRadius: 14)],
  // ice: 0 0 8px rgba(0,200,255,.5) (:613-616).
  'style-ice': [Shadow(color: Color(0x8000C8FF), blurRadius: 8)],
  // rainbow: 0 0 8px rgba(199,125,255,.35) (:619-622).
  'style-rainbow': [Shadow(color: Color(0x59C77DFF), blurRadius: 8)],
  // ocean: 0 0 8px rgba(56,189,248,.5) (:734).
  'style-ocean': [Shadow(color: Color(0x8038BDF8), blurRadius: 8)],
  // sakura: 0 0 8px rgba(255,126,182,.5) (:759).
  'style-sakura': [Shadow(color: Color(0x80FF7EB6), blurRadius: 8)],
  // galaxy: 0 0 8px rgba(192,132,252,.6) (:784).
  'style-galaxy': [Shadow(color: Color(0x99C084FC), blurRadius: 8)],
  // toxic: 0 0 8px rgba(132,255,59,.5) (:809).
  'style-toxic': [Shadow(color: Color(0x8084FF3B), blurRadius: 8)],
  // gold: 0 0 8px rgba(255,215,0,.5) (:838).
  'style-gold': [Shadow(color: Color(0x80FFD700), blurRadius: 8)],
  // vapor: 0 0 8px rgba(255,113,206,.5), 0 0 14px rgba(5,217,232,.3) (dual) (:867).
  'style-vapor': [
    Shadow(color: Color(0x80FF71CE), blurRadius: 8),
    Shadow(color: Color(0x4D05D9E8), blurRadius: 14),
  ],
  // blood: 0 0 8px rgba(255,30,30,.6) (:892).
  'style-blood': [Shadow(color: Color(0x99FF1E1E), blurRadius: 8)],
  // royal: 0 0 8px rgba(196,163,255,.5), 0 0 12px rgba(212,175,55,.3) (dual) (:917).
  'style-royal': [
    Shadow(color: Color(0x80C4A3FF), blurRadius: 8),
    Shadow(color: Color(0x4DD4AF37), blurRadius: 12),
  ],
  // circuit: 0 0 8px rgba(45,212,191,.5) (:942).
  'style-circuit': [Shadow(color: Color(0x802DD4BF), blurRadius: 8)],
  // eclipse: 0 0 8px rgba(255,170,90,.55), 0 0 16px rgba(255,120,60,.3) (dual) (:1252).
  'style-eclipse': [
    Shadow(color: Color(0x8CFFAA5A), blurRadius: 8),
    Shadow(color: Color(0x4DFF783C), blurRadius: 16),
  ],
  // crt: 0 0 8px rgba(255,176,0,.85) (:1284).
  'style-crt': [Shadow(color: Color(0xD9FFB000), blurRadius: 8)],
  // satoshi: NO text-shadow on .message-content (glow is preview-only) — absent.
};

/// The aurora gradient's blue glow (`text-shadow 0 0 10px rgba(91,140,255,.3)`,
/// styles-features.css:644), kept behind the gradient-clipped text — DARK mode
/// only (light resets `text-shadow: none`, styles-themes-responsive.css:889).
const Map<String, Shadow> _styleGradientGlow = {
  'style-aurora': Shadow(color: Color(0x4D5B8CFF), blurRadius: 10),
};

/// Bubble-layout-only text colour overrides (`body.chat-bubbles .message.
/// style-X .message-content { color }`, styles-features.css:3665-3673). fire and
/// ice paint a brighter glyph in bubbles than the IRC `#ffaa00`/`#00ccee`.
const Map<String, Color> _styleBubbleTextColor = {
  'style-fire': Color(0xFFFF6600),
  'style-ice': Color(0xFF00CCFF),
};

/// Styles that bold their glyphs (`font-weight: bold` on the inner spans).
/// satoshi (`styles-features.css:572`).
const Set<String> _styleBold = {'style-satoshi'};

/// Per-style `.message-content` padding — satoshi's plate carries its own
/// `padding: 10px 15px` (styles-features.css:548-549, kept by the light
/// override); eclipse/crt paint their plates with no extra padding.
const Map<String, EdgeInsets> _styleContentPadding = {
  'style-satoshi': EdgeInsets.symmetric(horizontal: 15, vertical: 10),
};

/// Dark-mode `.message-content` CONTAINER body-text colour for styles whose bare
/// body differs from their inner `> *` child colour. Only satoshi: the container
/// is white (`color:#FFFFFF`, styles-features.css:550) while its inner spans are
/// the bold orange `#f7931a` (`:571`). Real plain message text is bare nodes, so
/// the body reads white; the orange is reserved for links/mentions/emoji and the
/// shop preview (which wraps its sample in a `<span>`).
const Map<String, Color> _styleBodyColor = {
  'style-satoshi': Color(0xFFFFFFFF),
};

/// Light-mode `.message-content` CONTAINER body colour (the split styles). satoshi
/// body is `#7a5500` (`body.light-mode .message.style-satoshi .message-content`,
/// styles-themes-responsive.css:900); its inner children are `#c47a15` (`:905`).
const Map<String, Color> _styleLightBodyColor = {
  'style-satoshi': Color(0xFF7A5500),
};

/// Light-mode text colours (`body.light-mode .message.style-X .message-content`,
/// styles-themes-responsive.css:810-1041). For satoshi this is the INNER `> *`
/// child colour (`#c47a15`); the body uses the dimmer container [_styleLightBodyColor].
const Map<String, Color> _styleLightColor = {
  'style-matrix': Color(0xFF006600),
  'style-neon': Color(0xFF990099),
  'style-ghost': Color(0x73000000), // rgba(0,0,0,0.45)
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

/// Light-mode gradient overrides — aurora is the only style that stays a gradient
/// in light mode (`linear-gradient(120deg,#007766,#334499,#880066,#007766)`).
const Map<String, List<Color>> _styleLightGradient = {
  'style-aurora': [
    Color(0xFF007766),
    Color(0xFF334499),
    Color(0xFF880066),
    Color(0xFF007766),
  ],
};

/// Light-mode IRC content-background overrides (satoshi tints
/// `rgba(196,122,21,0.1)`, styles-themes-responsive.css:899-901).
const Map<String, Color> _styleLightContentBackground = {
  'style-satoshi': Color(0x1AC47A15),
};

/// Light-mode BUBBLE content-background overrides (`body.light-mode.chat-bubbles
/// .message.style-satoshi .message-content { background: rgba(247,147,26,.12)
/// !important }`, styles-themes-responsive.css:1417-1419; fire/ice share a
/// dedicated `rgba(0,0,0,.08)` fill instead of the generic black@.10 bubble,
/// :1412-1414).
const Map<String, Color> _styleLightBubbleContentBackground = {
  'style-satoshi': Color(0x1FF7931A),
  'style-fire': Color(0x14000000), // rgba(0,0,0,0.08)
  'style-ice': Color(0x14000000), // rgba(0,0,0,0.08)
};

/// solid-ui content-background overrides, dark. Satoshi's plate goes OPAQUE in
/// both layouts: `body.solid-ui.chat-bubbles .message.style-satoshi
/// .message-content { background: #4a3a1f !important }` (styles-themes-
/// responsive.css:1714) and `body.solid-ui:not(.chat-bubbles) … {
/// background-color: #4a3a1f }` (:1750).
const Map<String, Color> _styleSolidContentBackground = {
  'style-satoshi': Color(0xFF4A3A1F),
};

/// solid-ui content-background overrides, light: satoshi `#f3dcb4` in both
/// layouts (`body.solid-ui.light-mode[.chat-bubbles] .message.style-satoshi
/// .message-content`, styles-themes-responsive.css:1738/1764).
const Map<String, Color> _styleSolidLightContentBackground = {
  'style-satoshi': Color(0xFFF3DCB4),
};

/// Explicit glyph shadows for styles whose CSS `text-shadow` is not a single
/// soft glow. Glitch (`.style-glitch`) is a red/-2px + cyan/+2px chromatic split
/// (`styles-features.css:625-628`).
const Map<String, List<Shadow>> _styleGlyphShadows = {
  'style-glitch': [
    Shadow(color: Color(0xFFFF0000), offset: Offset(-2, 0)),
    Shadow(color: Color(0xFF00FFFF), offset: Offset(2, 0)),
  ],
};

/// Per-style repeating-SVG / scanline watermarks (`--style-pattern` /
/// `.message-content::before`), ported verbatim from `styles-features.css`.
/// Every textured `.message.style-X` is covered: the SVG path data, tile sizes
/// and `fill/stroke-opacity` alphas are the exact in-chat `--style-pattern`
/// values (`styles-features.css:593-943,1257,1286`) — NOT the denser
/// `.style-preview-*` alphas (those are a separate, shop-card-only pattern set).
///
/// Each tile is rendered behind `.message-content` via the same flutter_svg
/// tiling mechanism ([StyleWatermarkLayer] / [_TiledSvg]) used for satoshi /
/// matrix. The radial-glow half of the eclipse `--style-pattern` is folded into
/// the glow/background instead (Flutter has no tiled radial-gradient layer here).
final Map<String, StyleWatermark> styleWatermarks = {
  // satoshi: tiled ₿ glyph (styles-features.css:545-566), 50×40 tile.
  // satoshi: tiled ₿ glyph at baseline (0,30), font-size 32, #f7931a @ .2 — a
  // glyph tile (flutter_svg can't render the `<text>`); ₿ resolves via Noto Sans.
  'style-satoshi': StyleWatermark.glyphs(
    [GlyphTile('₿', 0, 30, 32)],
    const Size(50, 40),
    Color(0x33F7931A), // #f7931a @ 0.2
  ),
  // matrix: falling 10/01/11 monospace code (styles-features.css:593), 36×48 —
  // a glyph tile at the three SVG baselines, #00ff00 @ .13.
  'style-matrix': StyleWatermark.glyphs(
    [
      GlyphTile('10', 3, 13, 12, mono: true),
      GlyphTile('01', 19, 27, 12, mono: true),
      GlyphTile('11', 6, 41, 12, mono: true),
    ],
    const Size(36, 48),
    Color(0x2100FF00), // #00ff00 @ 0.13
  ),
  // eclipse: dim star dots (styles-features.css:1257), 60×60, PLUS the radial
  // warm-orange wash half of --style-pattern (`radial-gradient(circle at 20% 50%,
  // rgba(255,190,120,.14), transparent 55%)`, :1256) painted behind the text.
  'style-eclipse': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
        "<g fill='#ffd9a0' fill-opacity='0.12'><circle cx='14' cy='12' r='0.9'/>"
        "<circle cx='46' cy='30' r='0.7'/><circle cx='26' cy='48' r='0.8'/>"
        "</g></svg>",
    const Size(60, 60),
    radialWash: const RadialWash(
      color: Color(0x24FFBE78), // rgba(255,190,120,.14)
      center: Alignment(-0.6, 0), // circle at 20% 50%
      radius: 0.55, // transparent 55%
    ),
  ),
  // crt: amber phosphor scanlines — 1px line every 3px (styles-features.css:1286).
  'style-crt': const StyleWatermark.scanlines(
    color: Color(0x47FFB000), // rgba(255,176,0,0.28)
    scanlineGap: 3,
    scanlineThickness: 1,
  ),
  // fire: two flame teardrops (styles-features.css:610), 46×46.
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
  // ice: two snow-crystals (styles-features.css:616), 44×44.
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
  // ghost: two little ghosts (styles-features.css:604), 52×52.
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
  // ocean: two sine waves (styles-features.css:735), 48×24.
  'style-ocean': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'>"
        "<g fill='none' stroke='#38bdf8' stroke-opacity='0.16' stroke-width='1.4'>"
        "<path d='M0 12 Q6 6 12 12 T24 12 T36 12 T48 12'/>"
        "<path d='M0 20 Q6 14 12 20 T24 20 T36 20 T48 20'/></g></svg>",
    const Size(48, 24),
  ),
  // sakura: four rotated petals (styles-features.css:760), 50×50.
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
  // galaxy: star dots + a tiny sparkle cross (styles-features.css:785), 60×60.
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
  // toxic: radiation rings + dots (styles-features.css:810), 48×48.
  'style-toxic': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
        "<g fill='none' stroke='#84ff3b' stroke-opacity='0.14' stroke-width='1.2'>"
        "<circle cx='12' cy='12' r='3'/><circle cx='36' cy='34' r='3'/></g>"
        "<g fill='#84ff3b' fill-opacity='0.12'><circle cx='12' cy='12' r='1'/>"
        "<circle cx='36' cy='34' r='1'/></g></svg>",
    const Size(48, 48),
  ),
  // gold: two four-point sparkles (styles-features.css:839), 46×46.
  'style-gold': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
        "<g fill='#ffd700' fill-opacity='0.13'>"
        "<path d='M12 4 13.2 10.8 20 12 13.2 13.2 12 20 10.8 13.2 4 12 10.8 10.8z'/>"
        "<path d='M34 26 34.8 30.2 39 31 34.8 31.8 34 36 33.2 31.8 29 31 33.2 30.2z'/>"
        "</g></svg>",
    const Size(46, 46),
  ),
  // vapor: an angular grid stroke (styles-features.css:868), 24×24.
  'style-vapor': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>"
        "<g fill='none' stroke='#05d9e8' stroke-opacity='0.14' stroke-width='1'>"
        "<path d='M0 0H24V24'/></g></svg>",
    const Size(24, 24),
  ),
  // blood: two blood drops (styles-features.css:893), 44×44.
  'style-blood': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='44' height='44'>"
        "<g fill='#ff3b3b' fill-opacity='0.12'>"
        "<path d='M11 6c3 4 4.5 6 4.5 8a4.5 4.5 0 0 1-9 0c0-2 1.5-4 4.5-8z'/>"
        "<path d='M33 26c2 2.7 3 4 3 5.3a3 3 0 0 1-6 0c0-1.3 1-2.6 3-5.3z'/>"
        "</g></svg>",
    const Size(44, 44),
  ),
  // royal: a crown diamond + two corner chevrons (styles-features.css:918), 32×32.
  'style-royal': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
        "<g fill='none' stroke='#e8c860' stroke-opacity='0.16' stroke-width='1'>"
        "<path d='M16 4 22 12 16 20 10 12z'/>"
        "<path d='M0 20 6 28 0 36M32 20 26 28 32 36'/></g></svg>",
    const Size(32, 32),
  ),
  // circuit: PCB traces + solder nodes (styles-features.css:943), 48×48.
  'style-circuit': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
        "<g fill='none' stroke='#2dd4bf' stroke-opacity='0.16' stroke-width='1'>"
        "<path d='M6 6h12v12M18 6h12M30 6v10h12M6 24v12h10M16 36h14v8M30 30h12'/></g>"
        "<g fill='#2dd4bf' fill-opacity='0.22'><circle cx='6' cy='6' r='1.5'/>"
        "<circle cx='42' cy='16' r='1.5'/><circle cx='16' cy='36' r='1.5'/>"
        "<circle cx='42' cy='30' r='1.5'/></g></svg>",
    const Size(48, 48),
  ),
  // rainbow: stacked ROYGBIV arc-pairs (styles-features.css:622), 46×46.
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

/// Light-mode `--style-pattern` watermark swaps (`body.light-mode .message.
/// style-X .message-content { --style-pattern }`, styles-themes-responsive.css:
/// 810-1045). On a light surface the bright dark-mode SVG fills wash out (ghost
/// is the worst — white ghosts → invisible), so the PWA swaps to a darker fill
/// at a higher alpha. Styles absent here keep their dark-mode SVG in light too
/// (greens/icy hues read OK). Tile sizes are unchanged from the dark variants.
final Map<String, StyleWatermark> _styleLightWatermarks = {
  // ghost → #223044 @ 0.1 (was #ffffff @ 0.08) (:833).
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
  // matrix → #006600 @ 0.2 (:1029) — glyph tile (flutter_svg drops `<text>`).
  'style-matrix': StyleWatermark.glyphs(
    [
      GlyphTile('10', 3, 13, 12, mono: true),
      GlyphTile('01', 19, 27, 12, mono: true),
      GlyphTile('11', 6, 41, 12, mono: true),
    ],
    const Size(36, 48),
    Color(0x33006600), // #006600 @ 0.2
  ),
  // ocean → #38a8d8 @ 0.3 (:1014).
  'style-ocean': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'>"
        "<g fill='none' stroke='#38a8d8' stroke-opacity='0.3' stroke-width='1.4'>"
        "<path d='M0 12 Q6 6 12 12 T24 12 T36 12 T48 12'/>"
        "<path d='M0 20 Q6 14 12 20 T24 20 T36 20 T48 20'/></g></svg>",
    const Size(48, 24),
  ),
  // sakura → #c01f7a @ 0.24 (:1017).
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
  // galaxy → #6a2fb0 @ 0.32 (:1020).
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
  // toxic → #3a7a00 (stroke .3 / fill .24) (:1035).
  'style-toxic': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
        "<g fill='none' stroke='#3a7a00' stroke-opacity='0.3' stroke-width='1.2'>"
        "<circle cx='12' cy='12' r='3'/><circle cx='36' cy='34' r='3'/></g>"
        "<g fill='#3a7a00' fill-opacity='0.24'><circle cx='12' cy='12' r='1'/>"
        "<circle cx='36' cy='34' r='1'/></g></svg>",
    const Size(48, 48),
  ),
  // gold → #a07a00 @ 0.22 (:1032).
  'style-gold': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
        "<g fill='#a07a00' fill-opacity='0.22'>"
        "<path d='M12 4 13.2 10.8 20 12 13.2 13.2 12 20 10.8 13.2 4 12 10.8 10.8z'/>"
        "<path d='M34 26 34.8 30.2 39 31 34.8 31.8 34 36 33.2 31.8 29 31 33.2 30.2z'/>"
        "</g></svg>",
    const Size(46, 46),
  ),
  // vapor → #b9b3c2 @ 0.35 (:1009).
  'style-vapor': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>"
        "<g fill='none' stroke='#b9b3c2' stroke-opacity='0.35' stroke-width='1'>"
        "<path d='M0 0H24V24'/></g></svg>",
    const Size(24, 24),
  ),
  // royal → #9a7b1a @ 0.32 (:1038).
  'style-royal': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
        "<g fill='none' stroke='#9a7b1a' stroke-opacity='0.32' stroke-width='1'>"
        "<path d='M16 4 22 12 16 20 10 12z'/>"
        "<path d='M0 20 6 28 0 36M32 20 26 28 32 36'/></g></svg>",
    const Size(32, 32),
  ),
  // circuit → #0a7d70 (stroke .34 / fill .42) (:1041).
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

/// Translucent `.message-content { background-color }` painted by the styles
/// that have one (verbatim alpha from `css/styles-features.css`). Styles not
/// listed paint no content background.
const Map<String, Color> _styleContentBackground = {
  // .message.style-satoshi .message-content { background: rgba(247,147,26,.2) }
  'style-satoshi': Color(0x33F7931A),
  // .message.style-eclipse .message-content (the later override) rgba(18,14,28,.72)
  'style-eclipse': Color(0xB8120E1C),
  // .message.style-crt .message-content (the later override) rgba(10,8,2,.82)
  'style-crt': Color(0xD10A0802),
};

/// The supporter-style decoration (`.message.supporter-style`): gold glyphs with
/// a soft gold glow, a gold left accent bar and a faint gold wash behind the
/// bubble (`css/styles-features.css` lines 1084-1092).
const MessageStyleDecoration supporterStyleDecoration = MessageStyleDecoration(
  textColor: Color(0xFFFFD700),
  // text-shadow 0 0 8px rgba(255,215,0,.25) (was a uniform 10px blur).
  glowShadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
  glow: Color(0x40FFD700), // rgba(255,215,0,.25) — single-layer fallback
  // body.chat-bubbles .message.supporter-style .message-content { bg rgba(255,215,0,.12) }
  contentBackground: Color(0x1FFFD700), // rgba(255,215,0,.12) bubble wash
  // The gold wash is `body.chat-bubbles`-gated (:3692) — IRC paints only the
  // row gradient + bar, never a content plate.
  bubbleOnlyContentBackground: true,
  // body:not(.chat-bubbles) .message.supporter-style { bg gradient .08→.03 } (:1085)
  backgroundGradient: [Color(0x14FFD700), Color(0x08FFD700)],
  borderAccent: Color(0xFFFFD700),
);

/// Light-mode supporter style (`body.light-mode .message.supporter-style
/// .message-content { color:#8a6d00; text-shadow:none }` + the lighter gold
/// wash/border, styles-themes-responsive.css:1002,985). Darker gold text, no
/// glow, so it stays legible on a light bubble.
const MessageStyleDecoration supporterStyleDecorationLight =
    MessageStyleDecoration(
  textColor: Color(0xFF8A6D00),
  // body.light-mode.chat-bubbles .message.supporter-style .message-content
  // { background: rgba(180,150,0,0.08) !important } (themes:1421) — note the
  // 150 green channel (NOT the 140 of the wash/border rules).
  contentBackground: Color(0x14B49600), // rgba(180,150,0,.08) bubble wash
  // Bubble-only, like the dark wash — IRC light paints just the row gradient.
  bubbleOnlyContentBackground: true,
  // body.light-mode:not(.chat-bubbles) .message.supporter-style { bg gradient
  // rgba(180,140,0,.06→.02) } (:935).
  backgroundGradient: [Color(0x0FB48C00), Color(0x05B48C00)],
  borderAccent: Color(0xFFB8960A),
);

/// solid-ui supporter style, dark: the gold text/glow is unchanged, but the
/// translucent washes go opaque — bubble `.message-content` fill `#3d3520`
/// (`body.solid-ui.chat-bubbles .message.supporter-style .message-content
/// { background: #3d3520 !important }`, styles-themes-responsive.css:1718) and
/// the IRC row flattens to `#2a2418` + the same 3px `#ffd700` bar
/// (`body.solid-ui:not(.chat-bubbles) .message.supporter-style`, :1754-1757).
const MessageStyleDecoration supporterStyleDecorationSolid =
    MessageStyleDecoration(
  textColor: Color(0xFFFFD700),
  glowShadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
  glow: Color(0x40FFD700),
  contentBackground: Color(0xFF3D3520), // opaque bubble wash (:1718)
  bubbleOnlyContentBackground: true,
  // Flat row plate — a same-stop "gradient" so the IRC row path (which paints
  // [backgroundGradient]) renders the flat `#2a2418`.
  backgroundGradient: [Color(0xFF2A2418), Color(0xFF2A2418)],
  borderAccent: Color(0xFFFFD700),
);

/// solid-ui supporter style, light: bubble wash `#efe2a8` (`body.solid-ui.
/// light-mode.chat-bubbles … { background: #efe2a8 !important }`, styles-themes-
/// responsive.css:1742), IRC row flat `#f4ead0` + `#b8960a` bar (:1768-1771);
/// text keeps the light `#8a6d00` / no glow.
const MessageStyleDecoration supporterStyleDecorationSolidLight =
    MessageStyleDecoration(
  textColor: Color(0xFF8A6D00),
  contentBackground: Color(0xFFEFE2A8), // opaque bubble wash (:1742)
  bubbleOnlyContentBackground: true,
  backgroundGradient: [Color(0xFFF4EAD0), Color(0xFFF4EAD0)],
  borderAccent: Color(0xFFB8960A),
);

/// The supporter decoration for the current mode: [solidUi] selects the opaque
/// solid-ui plates, [isLight] the light palette.
MessageStyleDecoration supporterStyleDecorationFor(
    {required bool isLight, bool solidUi = false}) {
  if (solidUi) {
    return isLight
        ? supporterStyleDecorationSolidLight
        : supporterStyleDecorationSolid;
  }
  return isLight ? supporterStyleDecorationLight : supporterStyleDecoration;
}

/// Message styles whose DARK body-text colour rule is declared AFTER the
/// supporter gold rule (`.message.supporter-style .message-content
/// { color:#ffd700 !important }`, styles-features.css:1089) at equal
/// specificity — so they keep their own colour + text-shadow when both classes
/// are present: eclipse (:1249) and crt (:1281).
const Set<String> _darkStyleColorBeatsSupporter = {
  'style-eclipse',
  'style-crt',
};

/// Message styles whose LIGHT body-text colour rule is declared AFTER the light
/// supporter rule (`body.light-mode .message.supporter-style .message-content
/// { color:#8a6d00 !important }`, styles-themes-responsive.css:939) at equal
/// specificity — ocean/sakura/galaxy/toxic/blood/royal/circuit/gold (:987-1002)
/// and vapor (:1009) keep their own light colour; every other style (and
/// eclipse/crt, whose 3-class dark rules lose to the 4-class light supporter
/// rule) goes supporter gold-brown.
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

/// Composes the supporter-badge gold treatment ONTO an active message style —
/// the PWA adds BOTH classes to the message (`_applyShopClassesToMessage`,
/// shop.js:485-495), so the two cascade together rather than one replacing the
/// other:
///
/// * Row (IRC): supporter's gold 135deg wash + 3px gold left bar
///   (`body:not(.chat-bubbles) .message.supporter-style`) — no style paints
///   those, so they always compose in.
/// * Bubble fill: supporter's gold wash (`body.chat-bubbles .message.
///   supporter-style .message-content { background … !important }`,
///   styles-features.css:3692) is declared after every style's bubble
///   background at equal-or-winning specificity/importance, so it replaces the
///   style's bubble fill.
/// * Body text: supporter's `color:#ffd700 !important` + gold text-shadow
///   (:1089-1092) beat the style colour rules declared before them (source
///   order at equal specificity); the styles in
///   [_darkStyleColorBeatsSupporter] / [_lightStyleColorBeatsSupporter] are
///   declared later and keep their own text. The style's content plates
///   (satoshi/eclipse/crt), watermark, monospace/bold and the bubble-only
///   fire/ice colours (`body.chat-bubbles …`, 4 classes, :3664-3672) survive.
///
/// aurora is exempt: its text is gradient-clipped with
/// `-webkit-text-fill-color: transparent`, so the gold `color` never shows.
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
    // Supporter's `text-shadow: 0 0 8px gold@.25` (:1090) replaces the style's
    // stack (glitch's chromatic split included) whenever the gold colour wins;
    // light supporter resets `text-shadow: none` (themes:940).
    glowShadows: goldText ? supporter.glowShadows : styled.glowShadows,
    glyphShadows: goldText ? null : styled.glyphShadows,
    gradient: styled.gradient,
    gradientGlow: styled.gradientGlow,
    contentBackground: styled.contentBackground,
    bubbleOnlyContentBackground: styled.bubbleOnlyContentBackground,
    // Supporter's bubble wash wins over every style's bubble fill (dark
    // rgba(255,215,0,.12) at :3692; light rgba(180,150,0,.08) at themes:1421).
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

// =============================================================================
// Special cosmetics (auras / watermarks / prism / hologram). `.message.cosmetic-X`
// (styles-features.css:1099-1211). Composed onto the bubble/row in message_row.
// =============================================================================

/// Resolves the active special-cosmetic auras for [cosmetics] (in declared
/// order, excluding the redacted privacy item which is handled separately).
///
/// [isLight] selects the `body.light-mode .message.cosmetic-X` override — the
/// PWA ships one ONLY for gold; the other auras keep their dark values in light
/// mode (see [cosmeticAuraFor]).
List<CosmeticAura> resolveCosmeticAuras(UserCosmetics cosmetics,
    {bool isLight = false, bool solidUi = false}) {
  final out = <CosmeticAura>[];
  for (final id in cosmetics.cosmetics) {
    final aura = cosmeticAuraFor(id, isLight: isLight, solidUi: solidUi);
    if (aura != null) out.add(aura);
  }
  return out;
}

/// The aura for a single cosmetic [id], mode-aware. Only GOLD has a light-mode
/// override in the PWA; every other aura keeps its dark values in light mode
/// (styles-themes-responsive.css:923-931 is the sole `body.light-mode`
/// cosmetic-aura rule). [solidUi] likewise swaps in gold's `body.solid-ui`
/// opaque plates (:1722/:1746 bubble, :1759/:1773 IRC row) — the solid block
/// touches no other aura. Used by both the chat bubble and the shop card
/// preview (which keeps the glass defaults).
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

/// Cosmetic aura table (styles-features.css:1099-1211). Box-shadow inset/glow,
/// border accents, gradients + watermarks captured verbatim. Per-layout deltas
/// (the bubble's stronger gold ring/smaller glow, and which auras paint their
/// gradient as a bubble FILL vs only on the IRC row) are carried by the
/// `bubble*` fields.
final Map<String, CosmeticAura> _cosmeticAuras = {
  // cosmetic-aura-gold — IRC :1099-1103, bubble :3696-3702
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x59FFD700), // IRC ring rgba(255,215,0,.35)
    bubbleInsetColor: Color(0x8CFFD700), // bubble ring rgba(255,215,0,.55)
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x2EFFD700), // rgba(255,215,0,.18)
    glowBlur: 18, // IRC 18px
    bubbleGlowBlur: 12, // bubble 0 0 12px
    borderAccent: Color(0xFFFFD700),
    // IRC row bg gradient .05→.02; bubble fill gradient .16→.06.
    gradient: [Color(0x0DFFD700), Color(0x05FFD700)],
    bubbleGradient: [Color(0x29FFD700), Color(0x0FFFD700)],
    bubblePaintsGradient: true, // PWA bubble gold DOES paint a gold wash
  ),
  // cosmetic-aura-neon — IRC :1105-1109, bubble :1111-1113 (box-shadow only)
  'cosmetic-aura-neon': const CosmeticAura(
    id: 'cosmetic-aura-neon',
    insetColor: Color(0x8C00E5FF), // rgba(0,229,255,.55)
    insetRing: true,
    glowColor: Color(0x5200E5FF), // rgba(0,229,255,.32)
    glowBlur: 22,
    borderAccent: Color(0xFF00E5FF),
    // IRC row bg gradient only; bubble paints NO fill (box-shadow only).
    gradient: [Color(0x0F00E5FF), Color(0x0500E5FF)],
  ),
  // cosmetic-aura-rainbow (:1115-1139) — conic prism ring + soft glow (both layouts)
  'cosmetic-aura-rainbow': const CosmeticAura(
    id: 'cosmetic-aura-rainbow',
    glowColor: Color(0x4D9664FF), // rgba(150,100,255,.3)
    glowBlur: 16,
    prismRing: true,
  ),
  // cosmetic-frost (:1141-1167) — frosted inset + snowflake EDGES + icy wash
  'cosmetic-frost': CosmeticAura(
    id: 'cosmetic-frost',
    insetColor: const Color(0x8CE1F6FF), // rgba(225,246,255,.55)
    insetRing: true,
    glowColor: const Color(0x3396D2FF), // rgba(150,210,255,.2) — outer glow hue
    glowBlur: 10,
    background: const Color(0x29BEE6FF), // rgba(190,230,255,.16)
    watermark: StyleWatermark.svg(_frostSnowflakeSvg, const Size(18, 18)),
    edgeWatermark: true, // snowflakes tile along the 4 edges, not full-box
  ),
  // cosmetic-aura-phoenix — IRC :1169-1173, bubble :1175-1177 (box-shadow only)
  'cosmetic-aura-phoenix': const CosmeticAura(
    id: 'cosmetic-aura-phoenix',
    insetColor: Color(0x99FFA000), // rgba(255,160,0,.6)
    insetRing: true,
    glowColor: Color(0x66FF6E00), // rgba(255,110,0,.4)
    glowBlur: 26,
    borderAccent: Color(0xFFFF6A00),
    // IRC row bg gradient only; bubble paints NO fill.
    gradient: [Color(0x12FF6A00), Color(0x08FF0000)],
  ),
  // cosmetic-aura-cosmic — IRC :1179-1186 (gradient+starfield), bubble :1188-1195
  // (starfield tile only; the gradient is IRC-only).
  'cosmetic-aura-cosmic': CosmeticAura(
    id: 'cosmetic-aura-cosmic',
    insetColor: const Color(0x99A082FF), // rgba(160,130,255,.6)
    insetRing: true,
    glowColor: const Color(0x738C64FF), // rgba(140,100,255,.45)
    glowBlur: 26,
    borderAccent: const Color(0xFF7C5CFF),
    // IRC row bg gradient; bubble gets only the starfield watermark, NO gradient.
    gradient: const [Color(0x29462D8C), Color(0x0F0F0C23)],
    watermark: StyleWatermark.svg(_cosmicStarfieldSvg, const Size(60, 60)),
  ),
  // cosmetic-bubble-hologram (:1197-1211) — white sheen over multi-gradient
  // (both layouts via the overlay painter).
  'cosmetic-bubble-hologram': const CosmeticAura(
    id: 'cosmetic-bubble-hologram',
    insetColor: Color(0x80FFFFFF), // rgba(255,255,255,.5)
    insetRing: true,
    glowColor: Color(0x8096B4FF), // rgba(150,180,255,.5)
    glowBlur: 18,
    hologram: true,
  ),
};

/// Light-mode aura overrides. The PWA ships an explicit light rule ONLY for
/// GOLD (`body.light-mode … .cosmetic-aura-gold`, styles-themes-responsive.css:
/// 923-931). Every other aura (neon/rainbow/phoenix/cosmic/frost/hologram) has
/// NO light override in the CSS and keeps its dark values in light mode —
/// ground-truth parity forbids inventing muted variants for them. Auras absent
/// from this map fall back to the dark entry (see [cosmeticAuraFor]).
final Map<String, CosmeticAura> _cosmeticAurasLight = {
  // gold — explicit PWA light values. IRC: inset .3, glow 12px .12, border
  // #b8960a, bg .06→.02. Bubble: inset .5, glow 10px .15, fill .18→.06.
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x4DB48C00), // rgba(180,140,0,.3)
    bubbleInsetColor: Color(0x80B48C00), // rgba(180,140,0,.5)
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x1FB48C00), // rgba(180,140,0,.12)
    glowBlur: 12,
    // Bubble glow: 0 0 10px rgba(180,140,0,.15) (themes:931) — .15, not the
    // IRC .12.
    bubbleGlowColor: Color(0x26B48C00), // rgba(180,140,0,.15)
    bubbleGlowBlur: 10,
    borderAccent: Color(0xFFB8960A),
    gradient: [Color(0x0FB48C00), Color(0x05B48C00)], // .06→.02
    bubbleGradient: [Color(0x2EB48C00), Color(0x0FB48C00)], // .18→.06
    bubblePaintsGradient: true,
  ),
};

/// solid-ui aura overrides, DARK (`body.solid-ui`, styles-themes-responsive.
/// css:1722/:1759). Only GOLD is targeted by the solid block; ring/glow
/// box-shadows are untouched, so they carry over from the dark table.
final Map<String, CosmeticAura> _cosmeticAurasSolid = {
  // gold — IRC row flattens to the opaque `#2a2418` plate + the same `#ffd700`
  // bar (`body.solid-ui:not(.chat-bubbles) .message.cosmetic-aura-gold
  // { background: #2a2418; border-left: 3px solid #ffd700 }`, :1759-1762; the
  // base rule's inset ring / 18px glow persist — solid only resets background
  // + border-left). The UNSTYLED bubble keeps the GLASS gold wash: the
  // last-loaded features rule (`body.chat-bubbles .message:not([class*=
  // "style-"]).cosmetic-aura-gold .message-content { …gradient… !important }`,
  // styles-features.css:3700, specificity 0,5,1) outcascades the solid
  // `#38311e !important` plate (themes:1722, also 0,5,1 but declared in an
  // earlier sheet) — so [bubbleGradient] stays translucent and `#38311e` only
  // surfaces on STYLED messages via [bubbleStyledFill] (no `:not` gate on the
  // solid rule, and it beats every solid style plate).
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
    gradient: [Color(0xFF2A2418), Color(0xFF2A2418)], // flat opaque row plate
    bubbleGradient: [Color(0x29FFD700), Color(0x0FFFD700)], // glass wash wins
    bubblePaintsGradient: true,
    bubbleStyledFill: Color(0xFF38311E), // themes:1722, styled bubbles only
  ),
};

/// solid-ui aura overrides, LIGHT (`body.solid-ui.light-mode`). Gold's bubble
/// plate is `#f0e3ad` for styled AND unstyled messages here — the (0,6,1)
/// `body.solid-ui.light-mode.chat-bubbles .message.cosmetic-aura-gold
/// .message-content { background: #f0e3ad !important }` (themes:1746) beats the
/// (0,5,1) features glass wash — and the IRC row flattens to `#f4ead0` +
/// `#b8960a` bar (:1773-1776). Ring/glow keep the light-gold values.
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
    gradient: [Color(0xFFF4EAD0), Color(0xFFF4EAD0)], // flat opaque row plate
    bubbleGradient: [Color(0xFFF0E3AD), Color(0xFFF0E3AD)], // flat bubble plate
    bubblePaintsGradient: true,
    bubbleStyledFill: Color(0xFFF0E3AD),
  ),
};

// =============================================================================
// Rendering widgets for the watermark / aura textures.
// =============================================================================

/// Paints a [StyleWatermark] behind a message's content: either a tiled inline
/// SVG or programmatic scanlines (CRT). Returns a fill widget (no [Positioned]),
/// so wrap it in a `Positioned.fill` inside a `Stack` (z-index: -1 in the CSS),
/// clipped to the bubble radius by the caller.
class StyleWatermarkLayer extends StatelessWidget {
  const StyleWatermarkLayer({
    super.key,
    required this.watermark,
    this.edgeOnly = false,
  });

  final StyleWatermark watermark;

  /// Tile only along the four edges (a frosted border) rather than across the
  /// whole box — frost (`CosmeticAura.edgeWatermark`).
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
    // satoshi ₿ / matrix 10·01·11: a tiled TextPainter pattern (flutter_svg
    // can't render the `<text>` these `--style-pattern`s use).
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
    // The tiled SVG, optionally over a soft radial wash (eclipse's warm glow).
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
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, w.scanlineThickness), paint);
    }
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.w != w;
}

/// Tiles a TEXT watermark ([StyleWatermark.glyphs]) across the box with a
/// [TextPainter] — the satoshi ₿ and matrix 10·01·11 patterns flutter_svg can't
/// draw. Each [GlyphTile]'s `baselineY` is the SVG text baseline, so the painter
/// offsets each line up by its ascent to land the baseline there. ₿ resolves via
/// the bundled [kSansSymFont] (Noto Sans has U+20BF); matrix uses [kMonoFont].
class _GlyphTilePainter extends CustomPainter {
  _GlyphTilePainter(this.w);
  final StyleWatermark w;

  @override
  void paint(Canvas canvas, Size size) {
    final tile = w.size;
    if (tile.width <= 0 || tile.height <= 0) return;
    // Pre-lay each glyph once, then stamp it across the grid.
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

/// Repeats a small inline SVG [tile] across the available box. Uses
/// [SvgPicture.string] cells absolutely positioned in a Stack so it tiles
/// cheaply without rasterisation plumbing (and without RenderFlex overflow).
class _TiledSvg extends StatelessWidget {
  const _TiledSvg({required this.svg, required this.tile});
  final String svg;
  final Size tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 120.0;
        final cols = (w / tile.width).ceil();
        final rows = (h / tile.height).ceil();
        // Positioned tiles from the top-left (CSS `background-repeat` origin
        // 0 0); the partial last row/column is clipped by the wrapping ClipRect.
        // A Stack never reports RenderFlex overflow, unlike a Row/Column grid.
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
                  // A fresh SvgPicture per cell (a widget can't appear twice
                  // in the tree).
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

/// Tiles a small SVG only along the FOUR EDGES (a frosted border), mirroring the
/// frost `--style-pattern`'s `background-position: center top, center bottom,
/// left center, right center` + `repeat-x/repeat-y`: a horizontal strip across
/// the top and bottom, a vertical strip down the left and right.
class _EdgeTiledSvg extends StatelessWidget {
  const _EdgeTiledSvg({required this.svg, required this.tile});
  final String svg;
  final Size tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 120.0;
        final cols = (w / tile.width).ceil() + 1;
        final rows = (h / tile.height).ceil() + 1;
        // Inner vertical strips skip the top/bottom row so the corners aren't
        // double-stacked (the horizontal strips already cover them).
        final innerRows = rows - 2 > 0 ? rows - 2 : 0;
        // `center top/bottom` → the horizontal strips centre on the box;
        // `left/right center` → the vertical strips centre vertically. Cells are
        // absolutely positioned (a Stack never reports RenderFlex overflow —
        // the overhang is clipped by the wrapping ClipRect).
        final x0 = (w - cols * tile.width) / 2;
        final y0 = (h - innerRows * tile.height) / 2;
        // A fresh SvgPicture per cell (a widget can't appear twice in the tree).
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
            for (var r = 0; r < innerRows; r++)
              cellAt(0, y0 + r * tile.height),
            for (var r = 0; r < innerRows; r++)
              cellAt(w - tile.width, y0 + r * tile.height),
          ],
        );
      },
    );
  }
}

/// Paints the parts of a `.message.cosmetic-X` box-shadow / overlay that a plain
/// [BoxDecoration] can't express, as a `Positioned.fill` layer above the bubble
/// content: the conic prism ring (rainbow), the holographic sheen (hologram),
/// and — for any aura flagged [CosmeticAura.insetRing] — the
/// `box-shadow: inset 0 0 0 {insetWidth}px {insetColor}` rendered as a TRUE
/// inner ring (stroked fully inside the bubble edge) plus a soft inward feather,
/// instead of the outset glow `BoxShadow` can only approximate.
///
/// `message_row.dart._decorateBubble` routes `auras.where((a) => a.hasOverlay)`
/// through this painter and suppresses its own `Border.all` fallback for those
/// auras (`!lastAura.hasOverlay` guard), so every inset-ring aura draws exactly
/// ONE ring — the fully-inset stroke painted here.
class CosmeticOverlayPainter extends CustomPainter {
  CosmeticOverlayPainter({
    required this.aura,
    required this.radius,
    this.bubble = true,
    this.styleActive = false,
  });

  final CosmeticAura aura;
  final BorderRadius radius;

  /// Whether this overlay is painted in bubble layout (selects [CosmeticAura.
  /// bubbleInsetColor]). The prism ring / hologram sheen are layout-agnostic.
  final bool bubble;

  /// True when the message has an active `style-…` message style. The PWA
  /// gates the hologram iridescent fill + sheen on `.message:not([class*=
  /// "style-"]).cosmetic-bubble-hologram` (styles-features.css:1203-1211), so a
  /// styled message keeps only the box-shadow ring. Callers (message_row /
  /// previews) pass the active-style flag; the shop demo has no style.
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
      // 3px conic-gradient ring masked to the border. CSS `conic-gradient(from
      // 0deg …)` starts at 12 o'clock; SweepGradient starts at the +x axis
      // (3 o'clock), so rotate back a quarter turn to put red at the top.
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
    // Hologram fill + sheen are background-image layers the PWA drops when a
    // message style is active (`:not([class*="style-"])`); the ring stays.
    if (aura.hologram && !styleActive) {
      // 135deg multi-colour gradient + a 115deg white sheen. CSS
      // `background-blend-mode: screen, normal` (styles-features.css:1209):
      // only the white sheen screen-blends — the colour gradient composites
      // normally over the bubble fill.
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
    // True inset ring (`box-shadow: inset 0 0 0 {w}px {c}`). Drawn last so it
    // sits crisply on top of the hologram sheen / prism ring.
    final ringColor = aura.insetColorFor(bubble: bubble);
    if (aura.insetRing && ringColor != null) {
      final w = aura.insetWidth;
      // A stroked rounded-rect deflated by half its width keeps the whole stroke
      // INSIDE the bubble edge — matching CSS `inset 0 0 0 {w}px` (which paints
      // the ring entirely within the box) rather than a centred `Border.all`.
      final ringRect = rrect.deflate(w / 2);
      final ring = Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = w;
      canvas.drawRRect(ringRect, ring);
      // The soft inward feather an inset box-shadow casts: the ring colour at a
      // low alpha fading from the edge toward the centre, clipped to the bubble
      // so it never bleeds outside. (CSS inset shadows have 0 blur here, so this
      // is a faint accent, not a heavy halo — a fixed low alpha on the ring hue.)
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

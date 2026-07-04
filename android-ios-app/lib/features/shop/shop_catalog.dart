import 'package:flutter/material.dart';

import 'shop_models.dart';

/// The full Nymchat shop catalog, ported verbatim from the PWA
/// (`js/app.js` `this.shopItems`, docs/specs/04 §3.1). Item ids, names,
/// descriptions, prices, types, tiers and inline SVG icons match the web 1:1.
class ShopCatalog {
  ShopCatalog._();

  static const List<ShopItem> styles = [
    ShopItem(
      id: 'style-satoshi',
      name: 'Satoshi',
      description: 'Bitcoin-themed orange glow',
      price: 21420,
      type: 'message-style',
      tier: 'legendary',
      icon: _iconSatoshi,
    ),
    ShopItem(
      id: 'style-glitch',
      name: 'Glitch',
      description: 'Digital glitch effect',
      price: 10101,
      type: 'message-style',
      icon: _iconGlitch,
    ),
    ShopItem(
      id: 'style-aurora',
      name: 'Aurora',
      description: 'Neon aurora gradient',
      price: 2424,
      type: 'message-style',
      icon: _iconAurora,
    ),
    ShopItem(
      id: 'style-neon',
      name: 'Neon',
      description: 'Cyberpunk neon purple',
      price: 1984,
      type: 'message-style',
      icon: _iconNeon,
    ),
    ShopItem(
      id: 'style-ghost',
      name: 'Ghost',
      description: 'Mysterious ethereal fade',
      price: 666,
      type: 'message-style',
      icon: _iconGhost,
    ),
    ShopItem(
      id: 'style-matrix',
      name: 'Matrix',
      description: 'Green terminal glow effect',
      price: 1337,
      type: 'message-style',
      tier: 'legendary',
      icon: _iconMatrix,
    ),
    ShopItem(
      id: 'style-fire',
      name: 'Fire',
      description: 'Burning hot flame effect',
      price: 911,
      type: 'message-style',
      icon: _iconFire,
    ),
    ShopItem(
      id: 'style-ice',
      name: 'Ice',
      description: 'Cool frozen text effect',
      price: 777,
      type: 'message-style',
      icon: _iconIce,
    ),
    ShopItem(
      id: 'style-rainbow',
      name: 'Rainbow',
      description: 'Violet text with rainbow-arc watermark',
      price: 2222,
      type: 'message-style',
      icon: _iconRainbow,
    ),
    ShopItem(
      id: 'style-ocean',
      name: 'Ocean',
      description: 'Deep sea blue with waves',
      price: 1500,
      type: 'message-style',
      icon: _iconOcean,
    ),
    ShopItem(
      id: 'style-sakura',
      name: 'Sakura',
      description: 'Soft pink cherry blossoms',
      price: 3000,
      type: 'message-style',
      icon: _iconSakura,
    ),
    ShopItem(
      id: 'style-galaxy',
      name: 'Galaxy',
      description: 'Cosmic purple starfield',
      price: 4444,
      type: 'message-style',
      icon: _iconGalaxy,
    ),
    ShopItem(
      id: 'style-toxic',
      name: 'Toxic',
      description: 'Radioactive green hazard glow',
      price: 1300,
      type: 'message-style',
      icon: _iconToxic,
    ),
    ShopItem(
      id: 'style-gold',
      name: 'Midas',
      description: 'Luxurious gold',
      price: 8888,
      type: 'message-style',
      icon: _iconGold,
    ),
    ShopItem(
      id: 'style-vapor',
      name: 'Vaporwave',
      description: 'Retro pink and cyan sunset',
      price: 1995,
      type: 'message-style',
      icon: _iconVapor,
    ),
    ShopItem(
      id: 'style-blood',
      name: 'Blood',
      description: 'Dark crimson blood-drop text',
      price: 1313,
      type: 'message-style',
      icon: _iconBlood,
    ),
    ShopItem(
      id: 'style-royal',
      name: 'Royal',
      description: 'Regal purple with gold accents',
      price: 6000,
      type: 'message-style',
      icon: _iconRoyal,
    ),
    ShopItem(
      id: 'style-circuit',
      name: 'Circuit',
      description: 'Cyber circuit-board traces',
      price: 2048,
      type: 'message-style',
      icon: _iconCircuit,
    ),
  ];

  static const List<ShopItem> flair = [
    ShopItem(
      id: 'flair-crown',
      name: 'Crown',
      description: 'Royal golden crown badge',
      price: 5000,
      type: 'nickname-flair',
      icon: _iconCrown,
    ),
    ShopItem(
      id: 'flair-diamond',
      name: 'Diamond',
      description: 'Brilliant diamond badge',
      price: 10000,
      type: 'nickname-flair',
      tier: 'legendary',
      icon: _iconDiamond,
    ),
    ShopItem(
      id: 'flair-skull',
      name: 'Skull',
      description: 'Badass skull badge',
      price: 1666,
      type: 'nickname-flair',
      icon: _iconSkull,
    ),
    ShopItem(
      id: 'flair-star',
      name: 'Star',
      description: 'Shining star badge',
      price: 2500,
      type: 'nickname-flair',
      icon: _iconStar,
    ),
    ShopItem(
      id: 'flair-lightning',
      name: 'Lightning',
      description: 'Electric lightning bolt badge',
      price: 2100,
      type: 'nickname-flair',
      icon: _iconLightning,
    ),
    ShopItem(
      id: 'flair-heart',
      name: 'Heart',
      description: 'Loving heart badge',
      price: 1111,
      type: 'nickname-flair',
      icon: _iconHeart,
    ),
    ShopItem(
      id: 'flair-mask',
      name: 'Fawkes',
      description: 'Anonymous mask badge',
      price: 4200,
      type: 'nickname-flair',
      tier: 'legendary',
      icon: _iconMask,
    ),
    ShopItem(
      id: 'flair-rocket',
      name: 'Rocket',
      description: 'To the moon badge',
      price: 2300,
      type: 'nickname-flair',
      icon: _iconRocket,
    ),
    ShopItem(
      id: 'flair-shield',
      name: 'Shield',
      description: 'Supporter of encryption badge',
      price: 1900,
      type: 'nickname-flair',
      icon: _iconShield,
    ),
    ShopItem(
      id: 'flair-flame',
      name: 'Flame',
      description: 'Blazing fire badge',
      price: 1200,
      type: 'nickname-flair',
      icon: _iconFlame,
    ),
    ShopItem(
      id: 'flair-snowflake',
      name: 'Snowflake',
      description: 'Frosty winter badge',
      price: 1400,
      type: 'nickname-flair',
      icon: _iconSnowflake,
    ),
    ShopItem(
      id: 'flair-moon',
      name: 'Moon',
      description: 'Mystic crescent moon badge',
      price: 1600,
      type: 'nickname-flair',
      icon: _iconMoon,
    ),
    ShopItem(
      id: 'flair-sun',
      name: 'Sun',
      description: 'Radiant sun badge',
      price: 1500,
      type: 'nickname-flair',
      icon: _iconSun,
    ),
    ShopItem(
      id: 'flair-leaf',
      name: 'Leaf',
      description: 'Natural green leaf badge',
      price: 900,
      type: 'nickname-flair',
      icon: _iconLeaf,
    ),
    ShopItem(
      id: 'flair-music',
      name: 'Music',
      description: 'Melodic music note badge',
      price: 1100,
      type: 'nickname-flair',
      icon: _iconMusic,
    ),
    ShopItem(
      id: 'flair-eye',
      name: 'All-Seeing',
      description: 'Watchful all-seeing eye badge',
      price: 1800,
      type: 'nickname-flair',
      icon: _iconEye,
    ),
    ShopItem(
      id: 'flair-anchor',
      name: 'Anchor',
      description: 'Steadfast anchor badge',
      price: 1000,
      type: 'nickname-flair',
      icon: _iconAnchor,
    ),
    ShopItem(
      id: 'flair-gem',
      name: 'Ruby',
      description: 'Precious ruby gem badge',
      price: 3300,
      type: 'nickname-flair',
      icon: _iconGem,
    ),
  ];

  static const List<ShopItem> special = [
    ShopItem(
      id: 'supporter-badge',
      name: 'Nymchat Supporter',
      description: 'Special supporter badge with golden messages',
      price: 42069,
      type: 'supporter',
      icon: trophyIcon,
    ),
    ShopItem(
      id: 'cosmetic-aura-gold',
      name: 'Gold Aura',
      description: 'Golden glow around your messages',
      price: 3500,
      type: 'cosmetic',
      cssClass: 'cosmetic-aura-gold',
      icon: _iconAuraGold,
    ),
    ShopItem(
      id: 'cosmetic-redacted',
      name: 'Redacted',
      description: 'Remove each message after 10 seconds',
      price: 2800,
      type: 'cosmetic',
      cssClass: 'cosmetic-redacted',
      icon: _iconRedacted,
    ),
    ShopItem(
      id: 'cosmetic-aura-neon',
      name: 'Neon Aura',
      description: 'Electric cyan glow around your messages',
      price: 3200,
      type: 'cosmetic',
      cssClass: 'cosmetic-aura-neon',
      icon: _iconAuraNeon,
    ),
    ShopItem(
      id: 'cosmetic-aura-rainbow',
      name: 'Prism Aura',
      description: 'Legendary rainbow ring that wraps your whole message',
      price: 11000,
      type: 'cosmetic',
      tier: 'legendary',
      cssClass: 'cosmetic-aura-rainbow',
      icon: _iconAuraRainbow,
    ),
    ShopItem(
      id: 'cosmetic-frost',
      name: 'Frostbite',
      description: 'Frosted-glass message with icy snowflake accents',
      price: 2600,
      type: 'cosmetic',
      cssClass: 'cosmetic-frost',
      icon: _iconFrost,
    ),
    ShopItem(
      id: 'cosmetic-aura-phoenix',
      name: 'Phoenix Aura',
      description: 'Legendary rising-flame aura around your messages',
      price: 12000,
      type: 'cosmetic',
      tier: 'legendary',
      cssClass: 'cosmetic-aura-phoenix',
      icon: _iconAuraPhoenix,
    ),
    ShopItem(
      id: 'cosmetic-aura-cosmic',
      name: 'Cosmic Aura',
      description: 'Starfield aura around your messages',
      price: 5000,
      type: 'cosmetic',
      cssClass: 'cosmetic-aura-cosmic',
      icon: _iconAuraCosmic,
    ),
    ShopItem(
      id: 'cosmetic-bubble-hologram',
      name: 'Holographic',
      description: 'Legendary holographic finish on your whole message',
      price: 13500,
      type: 'cosmetic',
      tier: 'legendary',
      cssClass: 'cosmetic-bubble-hologram',
      icon: _iconHologram,
    ),
  ];

  static const List<ShopItem> limited = [
    ShopItem(
      id: 'flair-genesis',
      name: 'Genesis',
      description: 'Founders-only numbered emblem. Only 100 will ever exist.',
      price: 25000,
      type: 'nickname-flair',
      tier: 'legendary',
      maxSupply: 100,
      icon: _iconGenesis,
    ),
    ShopItem(
      id: 'style-eclipse',
      name: 'Eclipse',
      description: 'A rare eclipse-themed message style. Limited drop of 1,000.',
      price: 9000,
      type: 'message-style',
      maxSupply: 1000,
      startsAt: 1735689600000,
      endsAt: 1798761600000,
      icon: _iconEclipse,
    ),
    ShopItem(
      id: 'style-crt',
      name: 'CRT',
      description:
          'A limited drop of 250. Amber-phosphor terminal text with scanlines.',
      price: 12000,
      type: 'message-style',
      tier: 'legendary',
      maxSupply: 250,
      startsAt: 1735689600000,
      endsAt: 1798761600000,
      icon: _iconCrt,
    ),
  ];

  static const List<ShopItem> bundles = [
    ShopItem(
      id: 'bundle-starter',
      name: 'Starter Pack',
      description: 'Flame flair, Ice style and Frostbite cosmetic at a discount.',
      price: 3000,
      type: 'bundle',
      bundle: ['flair-flame', 'style-ice', 'cosmetic-frost'],
      icon: _iconBundleStarter,
    ),
    ShopItem(
      id: 'bundle-legendary',
      name: 'Legendary Vault',
      description: 'All three legendary cosmetics together — best value.',
      price: 30000,
      type: 'bundle',
      bundle: [
        'cosmetic-aura-phoenix',
        'cosmetic-aura-rainbow',
        'cosmetic-bubble-hologram',
      ],
      icon: _iconBundleLegendary,
    ),
    ShopItem(
      id: 'bundle-everything',
      name: 'Everything Pack',
      description:
          'Every message style, flair and special item in one go — the ultimate '
          'discount. (Excludes limited numbered editions.)',
      price: 149999,
      type: 'bundle',
      bundle: [],
      icon: _iconBundleEverything,
    ),
  ];

  /// Every catalog item across all tabs.
  static final List<ShopItem> all = [
    ...styles,
    ...flair,
    ...special,
    ...limited,
    ...bundles,
  ];

  static final Map<String, ShopItem> _byId = {
    for (final it in all) it.id: it,
  };

  static ShopItem? byId(String id) => _byId[id];

  /// The component item ids granted by a bundle. For `bundle-everything` the
  /// PWA fills the (empty) `bundle` array at startup from every non-limited,
  /// non-bundle catalog item (`js/app.js` lines 2061-2069); we compute the same
  /// list here so the Everything Pack actually grants its components. Other
  /// bundles return their static [ShopItem.bundle] list.
  static List<String> bundleComponents(String id) {
    if (id == 'bundle-everything') {
      return _everythingComponents;
    }
    return byId(id)?.bundle ?? const <String>[];
  }

  /// Every non-limited (no `maxSupply`), non-bundle item id — the Everything
  /// Pack's contents, mirroring the PWA's startup computation.
  static final List<String> _everythingComponents = [
    ...styles,
    ...flair,
    ...special,
  ].where((it) => it.maxSupply == null).map((it) => it.id).toList();

  // ---------------------------------------------------------------------------
  // Inline SVG trophy used for the supporter badge (PWA getSupporterTrophyIcon).
  // ---------------------------------------------------------------------------
  static const String trophyIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
      'width="1em" height="1em" fill="none" stroke="currentColor" '
      'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" '
      'vector-effect="non-scaling-stroke" role="img" aria-label="Trophy">'
      '<title>Trophy</title>'
      '<path d="M7 4h10v6a5 5 0 0 1-10 0V4z"/>'
      '<path d="M7 6H4.5a2.5 2.5 0 0 0 2.5 2.5"/>'
      '<path d="M17 6h2.5a2.5 2.5 0 0 1-2.5 2.5"/>'
      '<path d="M12 15v3"/><path d="M9 21h6"/><path d="M10 18h4l.5 3h-5z"/></svg>';

  /// Flair SVG, stamping the edition number for numbered editions (Genesis).
  /// Mirrors `_flairIconHtml(id, edition)`.
  static String flairIcon(String id, [int? edition]) {
    final item = byId(id);
    if (item == null) return '';
    if (id == 'flair-genesis' && edition != null && edition > 0) {
      final txt = '<text x="12" y="19.4" text-anchor="middle" font-size="7.5" '
          'font-weight="700" fill="currentColor" stroke="none">$edition</text>';
      return item.icon.replaceFirst('</svg>', '$txt</svg>');
    }
    return item.icon;
  }

  // ---------------------------------------------------------------------------
  // Visual tables for cosmetic previews (from css/styles-features.css).
  // ---------------------------------------------------------------------------

  /// Text colour + glow per message style (`.message.style-X .message-content`).
  static const Map<String, MessageStyleVisual> styleVisuals = {
    'style-satoshi': MessageStyleVisual(
      color: Color(0xFFF7931A),
      glow: Color(0x33F7931A),
      // .message.style-satoshi .message-content { background: rgba(247,147,26,.2) }
      contentBackground: Color(0x33F7931A),
    ),
    'style-glitch': MessageStyleVisual(
      color: Color(0xFF00FF00),
      glow: Color(0x6600FFFF),
      // text-shadow: -2px 0 #ff0000, 2px 0 #00ffff (styles-features.css:625-628).
      glyphShadows: [
        Shadow(color: Color(0xFFFF0000), offset: Offset(-2, 0)),
        Shadow(color: Color(0xFF00FFFF), offset: Offset(2, 0)),
      ],
    ),
    'style-aurora': MessageStyleVisual(
      color: Color(0xFF5B8CFF),
      // linear-gradient(120deg,#00ffd5,#5b8cff,#ff00ea,#00ffd5) — the trailing
      // #00ffd5 closes the cyan wrap (was a 3-stop that dropped it). The 120°
      // diagonal + blue glow are applied in message_row's ShaderMask.
      gradient: [
        Color(0xFF00FFD5),
        Color(0xFF5B8CFF),
        Color(0xFFFF00EA),
        Color(0xFF00FFD5),
      ],
    ),
    'style-neon': MessageStyleVisual(
      color: Color(0xFFFF00FF),
      glow: Color(0xCCFF00FF),
    ),
    'style-ghost': MessageStyleVisual(
      color: Color(0xB3FFFFFF),
      glow: Color(0x80FFFFFF),
    ),
    'style-matrix': MessageStyleVisual(
      color: Color(0xFF00FF00),
      glow: Color(0xCC00FF00),
    ),
    'style-fire': MessageStyleVisual(
      color: Color(0xFFFFAA00),
      glow: Color(0xCCFFA000),
    ),
    'style-ice': MessageStyleVisual(
      color: Color(0xFF00CCEE),
      glow: Color(0x8000C8FF),
    ),
    'style-rainbow': MessageStyleVisual(
      color: Color(0xFFC77DFF),
      glow: Color(0x59C77DFF),
    ),
    'style-ocean': MessageStyleVisual(
      color: Color(0xFF38BDF8),
      glow: Color(0x8038BDF8),
    ),
    'style-sakura': MessageStyleVisual(
      color: Color(0xFFFF7EB6),
      glow: Color(0x80FF7EB6),
    ),
    'style-galaxy': MessageStyleVisual(
      color: Color(0xFFC084FC),
      glow: Color(0x99C084FC),
    ),
    'style-toxic': MessageStyleVisual(
      color: Color(0xFF84FF3B),
      glow: Color(0x8084FF3B),
    ),
    'style-gold': MessageStyleVisual(
      color: Color(0xFFFFD700),
      glow: Color(0x80FFD700),
    ),
    'style-vapor': MessageStyleVisual(
      color: Color(0xFFFF71CE),
      glow: Color(0x80FF71CE),
    ),
    'style-blood': MessageStyleVisual(
      color: Color(0xFFFF3B3B),
      glow: Color(0x99FF1E1E),
    ),
    'style-royal': MessageStyleVisual(
      color: Color(0xFFC4A3FF),
      glow: Color(0x80C4A3FF),
    ),
    'style-circuit': MessageStyleVisual(
      color: Color(0xFF2DD4BF),
      glow: Color(0x802DD4BF),
    ),
    'style-eclipse': MessageStyleVisual(
      color: Color(0xFFFFCAA0),
      glow: Color(0x8CFFAA5A),
      // .message.style-eclipse .message-content { background: rgba(18,14,28,.72) }
      contentBackground: Color(0xB8120E1C),
    ),
    'style-crt': MessageStyleVisual(
      color: Color(0xFFFFB000),
      glow: Color(0xD9FFB000),
      monospace: true,
      // .message.style-crt .message-content { background: rgba(10,8,2,.82) }
      contentBackground: Color(0xD10A0802),
    ),
  };

  /// Aura accent + gradient + exact box-shadow layers per cosmetic
  /// (`.message.cosmetic-X`, `styles-features.css:1099-1211`). The preview
  /// bubble (and rendered message) compose [CosmeticVisual.boxShadows] onto the
  /// bubble; legendary ring/sheen flagged via [ringGradient]/[sheenGradient].
  static const Map<String, CosmeticVisual> cosmeticVisuals = {
    // inset 0 0 0 1px rgba(255,215,0,.35), 0 0 18px rgba(255,215,0,.18)
    'cosmetic-aura-gold': CosmeticVisual(
      accent: Color(0xFFFFD700),
      gradient: [Color(0x0DFFD700), Color(0x05FFD700)],
      borderLeft: Color(0xFFFFD700),
      boxShadows: [
        BoxShadow(color: Color(0x59FFD700), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x2EFFD700), blurRadius: 18),
      ],
    ),
    // inset 0 0 0 1px rgba(0,229,255,.55), 0 0 22px rgba(0,229,255,.32)
    'cosmetic-aura-neon': CosmeticVisual(
      accent: Color(0xFF00E5FF),
      gradient: [Color(0x0F00E5FF), Color(0x0500E5FF)],
      borderLeft: Color(0xFF00E5FF),
      boxShadows: [
        BoxShadow(color: Color(0x8C00E5FF), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x5200E5FF), blurRadius: 22),
      ],
    ),
    // conic prism ring + 0 0 16px rgba(150,100,255,.3)
    'cosmetic-aura-rainbow': CosmeticVisual(
      accent: Color(0xFF9664FF),
      gradient: [
        Color(0xFFFF0080),
        Color(0xFF7A5CFF),
        Color(0xFF00E5FF),
        Color(0xFF7AFFAA),
      ],
      boxShadows: [BoxShadow(color: Color(0x4D9664FF), blurRadius: 16)],
      ringGradient: [
        Color(0xFFFF2D2D),
        Color(0xFFFF8A00),
        Color(0xFFFFE600),
        Color(0xFF33DD00),
        Color(0xFF00C3FF),
        Color(0xFF2A5BFF),
        Color(0xFFB13BFF),
        Color(0xFFFF2D2D),
      ],
    ),
    // inset 0 0 0 1px rgba(255,160,0,.6), 0 0 26px rgba(255,110,0,.4)
    'cosmetic-aura-phoenix': CosmeticVisual(
      accent: Color(0xFFFF6A00),
      gradient: [Color(0x12FF6A00), Color(0x08FF0000)],
      borderLeft: Color(0xFFFF6A00),
      boxShadows: [
        BoxShadow(color: Color(0x99FFA000), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x66FF6E00), blurRadius: 26),
      ],
    ),
    // inset 0 0 0 1px rgba(160,130,255,.6), 0 0 26px rgba(140,100,255,.45)
    'cosmetic-aura-cosmic': CosmeticVisual(
      accent: Color(0xFF7C5CFF),
      gradient: [Color(0x29462D8C), Color(0x0F0F0C23)],
      borderLeft: Color(0xFF7C5CFF),
      boxShadows: [
        BoxShadow(color: Color(0x99A082FF), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x738C64FF), blurRadius: 26),
      ],
    ),
    // inset 0 0 0 1px rgba(225,246,255,.55), 0 0 10px rgba(150,210,255,.2)
    'cosmetic-frost': CosmeticVisual(
      accent: Color(0xFF68B8E6),
      gradient: [Color(0x29BEE6FF), Color(0x14BEE6FF)],
      boxShadows: [
        BoxShadow(color: Color(0x8CE1F6FF), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x3396D2FF), blurRadius: 10),
      ],
    ),
    // inset 0 0 0 1px rgba(255,255,255,.5), 0 0 18px rgba(150,180,255,.5)
    'cosmetic-bubble-hologram': CosmeticVisual(
      accent: Color(0xFF96B4FF),
      gradient: [
        Color(0x66FF00C8),
        Color(0x6600C8FF),
        Color(0x6678FFAA),
        Color(0x66FFE100),
      ],
      boxShadows: [
        BoxShadow(color: Color(0x80FFFFFF), blurRadius: 1, spreadRadius: 1),
        BoxShadow(color: Color(0x8096B4FF), blurRadius: 18),
      ],
      sheenGradient: [
        Color(0x66FF00C8),
        Color(0x6600C8FF),
        Color(0x6678FFAA),
        Color(0x66FFE100),
        Color(0x66FF00C8),
      ],
    ),
    'cosmetic-redacted': CosmeticVisual(accent: Color(0xFFFFFFFF)),
  };

  /// A representative repeating glyph for a textured style's watermark
  /// (`--style-pattern`, `styles-features.css:946-990`). The PWA tiles a
  /// per-style SVG behind the content; on native we approximate the highest-value
  /// ones with a tiled character (satoshi `₿`, matrix `10`, gold `✦`, …). Styles
  /// without a glyph return null and render with colour + glow only. CRT/eclipse
  /// use dedicated painters (scanlines / radial), not a glyph.
  static const Map<String, String> _stylePatternGlyphs = {
    'style-satoshi': '₿',
    'style-matrix': '10',
    'style-gold': '✦',
    'style-galaxy': '✦',
    'style-toxic': '☢',
    'style-royal': '♛',
    'style-blood': '🩸',
    'style-sakura': '✿',
    'style-ocean': '〜',
    'style-circuit': '⌁',
    'style-vapor': '░',
    'style-fire': '🔥',
    'style-ice': '❄',
    'style-ghost': '👻',
    'style-rainbow': '◠',
  };

  /// The watermark glyph for [styleId], or null when the style has no tiled
  /// pattern (see [_stylePatternGlyphs]).
  static String? stylePatternGlyph(String styleId) =>
      _stylePatternGlyphs[styleId];

  /// The total value of a bundle's components — `sum(component.price)` — used to
  /// render the "Save X% · N sats value" badge (`shop.js:896-902`). Returns 0
  /// for non-bundles or empty bundles.
  static int bundleValue(String id) {
    var sum = 0;
    for (final comp in bundleComponents(id)) {
      sum += byId(comp)?.price ?? 0;
    }
    return sum;
  }

  /// The discount percent of a bundle vs its component value, rounded like the
  /// PWA (`Math.round((1 - price/sum) * 100)`); 0 when there is no saving.
  static int bundleSavePercent(String id) {
    final item = byId(id);
    if (item == null) return 0;
    final sum = bundleValue(id);
    if (sum <= item.price) return 0;
    return ((1 - item.price / sum) * 100).round();
  }

  // ===========================================================================
  // SVG icon constants (ported verbatim from js/app.js).
  // ===========================================================================
  static const String _svgHead =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
      'width="1em" height="1em" fill="none" stroke="currentColor" '
      'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" '
      'vector-effect="non-scaling-stroke">';

  static const String _iconSatoshi = '$_svgHead'
      '<circle cx="12" cy="12" r="9"/><path d="M9.3 6.8V17.2"/>'
      '<path d="M9.3 6.8H13C15 6.8 16.2 7.9 16.2 9.6C16.2 11.3 15 12 13 12H9.3"/>'
      '<path d="M9.3 12H13.4C15.5 12 16.7 13 16.7 14.6C16.7 16.2 15.5 17.2 13.4 17.2H9.3"/>'
      '<path d="M11.2 5V6.8M13 5V6.8"/><path d="M11.2 17.2V19M13 17.2V19"/></svg>';
  static const String _iconGlitch = '$_svgHead'
      '<rect x="3" y="5" width="18" height="12" rx="2"/>'
      '<path d="M6 9H11 M13 9H18 M5 12H12 M14 12H17 M7 15H11 M12 15H18"/></svg>';
  static const String _iconAurora = '$_svgHead'
      '<path d="M2 15 Q7 12 12 15 T22 15"/><path d="M2 12 Q7 9 12 12 T22 12"/>'
      '<path d="M2 9 Q7 6 12 9 T22 9"/></svg>';
  static const String _iconNeon = '$_svgHead'
      '<rect x="3.5" y="5" width="17" height="12" rx="3"/>'
      '<path d="M17 8v2 M16 9h2"/></svg>';
  static const String _iconGhost = '$_svgHead'
      '<path d="M12 4c-3.5 0-6 2.6-6 6v5.5c0 .8.7 1.5 1.5 1.5.7 0 1.3-.4 1.9-.9.6.6 1.4.9 2.6.9s2-.3 2.6-.9c.6.5 1.2.9 1.9.9.8 0 1.5-.7 1.5-1.5V10c0-3.4-2.5-6-6-6Z"/>'
      '<circle cx="9.5" cy="11" r="1" fill="currentColor" stroke="none"/>'
      '<circle cx="14.5" cy="11" r="1" fill="currentColor" stroke="none"/></svg>';
  static const String _iconMatrix = '$_svgHead'
      '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M2 19H22"/>'
      '<path d="M7 9V12 M10 8V12 M13 10V13 M16 8.5V13"/></svg>';
  static const String _iconFire = '$_svgHead'
      '<path d="M12 3c3 3 6 6 6 9.5 0 3.6-2.7 6.5-6 6.5s-6-2.9-6-6.5C6 9 9 6 12 3Z"/>'
      '<path d="M12 8c1.9 1.7 3 3.4 3 5 0 1.9-1.3 3.5-3 3.5s-3-1.6-3-3.5c0-1.6 1.1-3.3 3-5Z"/></svg>';
  static const String _iconIce = '$_svgHead'
      '<path d="M12 2V22"/><path d="M2 12H22"/><path d="M4.9 6.5L19.1 17.5"/>'
      '<path d="M19.1 6.5L4.9 17.5"/></svg>';
  static const String _iconRainbow = '$_svgHead'
      '<path d="M4 16a8 8 0 0 1 16 0"/><path d="M6.5 16a5.5 5.5 0 0 1 11 0"/>'
      '<path d="M9 16a3 3 0 0 1 6 0"/></svg>';
  static const String _iconOcean = '$_svgHead'
      '<path d="M2 8 Q5 5 8 8 T14 8 T20 8 T22 8"/>'
      '<path d="M2 13 Q5 10 8 13 T14 13 T20 13 T22 13"/>'
      '<path d="M2 18 Q5 15 8 18 T14 18 T20 18 T22 18"/></svg>';
  static const String _iconSakura = '$_svgHead'
      '<path d="M12 12c0-3-1.5-5-3-6 2 0 4 1.2 4 3.5"/>'
      '<path d="M12 12c2.4-1.7 3-4.1 3-6 1.2 1.6 1.4 4-.5 5.4"/>'
      '<path d="M12 12c2.9.6 5.2-.3 6.8-1.5-.4 2-2.3 3.4-4.6 3.1"/>'
      '<path d="M12 12c1.1 2.7.6 5.1-.5 6.9-1.2-1.6-1.3-4 .2-5.6"/>'
      '<path d="M12 12c-2.6 1.5-3.7 3.8-4.1 5.9-1.2-1.7-.9-4 1-5.3"/>'
      '<circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/></svg>';
  static const String _iconGalaxy = '$_svgHead'
      '<circle cx="12" cy="12" r="5"/>'
      '<ellipse cx="12" cy="12" rx="10" ry="3.5" transform="rotate(-25 12 12)"/>'
      '<circle cx="4" cy="6" r="0.6" fill="currentColor" stroke="none"/>'
      '<circle cx="20" cy="18" r="0.6" fill="currentColor" stroke="none"/></svg>';
  static const String _iconToxic = '$_svgHead'
      '<circle cx="12" cy="12" r="2.2"/>'
      '<path d="M12 9.8V4.5a7.5 7.5 0 0 0-6.5 3.8l4.6 2.6"/>'
      '<path d="M13.9 13l4.6 2.6A7.5 7.5 0 0 0 18.5 8.3L13.9 11"/>'
      '<path d="M10.1 13l-4.6 2.6A7.5 7.5 0 0 0 12 19.5V14.2"/></svg>';
  static const String _iconGold = '$_svgHead'
      '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="5"/>'
      '<path d="M12 9.5v5M10.5 11h2.2a1.2 1.2 0 0 1 0 2.4H10.5"/></svg>';
  static const String _iconVapor = '$_svgHead'
      '<path d="M6 11a6 6 0 0 1 12 0"/>'
      '<path d="M7 7.5h10M6.4 9.2h11.2M6 11h12"/>'
      '<path d="M3 15h18M5 18h14M8 21h8"/></svg>';
  static const String _iconBlood = '$_svgHead'
      '<path d="M12 3c4 5 6 8 6 11a6 6 0 0 1-12 0c0-3 2-6 6-11Z"/>'
      '<path d="M12 16a2.5 2.5 0 0 1-2.5-2.5"/></svg>';
  static const String _iconRoyal = '$_svgHead'
      '<path d="M4 8l3 9h10l3-9-4.5 3.5L12 6 8.5 11.5Z"/>'
      '<circle cx="4" cy="8" r="1.2" fill="currentColor" stroke="none"/>'
      '<circle cx="20" cy="8" r="1.2" fill="currentColor" stroke="none"/>'
      '<circle cx="12" cy="6" r="1.2" fill="currentColor" stroke="none"/></svg>';
  static const String _iconCircuit = '$_svgHead'
      '<rect x="8" y="8" width="8" height="8" rx="1"/>'
      '<path d="M12 8V4M12 20v-4M8 12H4M20 12h-4"/>'
      '<circle cx="12" cy="4" r="1" fill="currentColor" stroke="none"/>'
      '<circle cx="4" cy="12" r="1" fill="currentColor" stroke="none"/>'
      '<circle cx="20" cy="12" r="1" fill="currentColor" stroke="none"/>'
      '<circle cx="12" cy="20" r="1" fill="currentColor" stroke="none"/></svg>';

  static const String _iconCrown =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.16 1.66 21.69 21.69" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<polyline points="3 9 7 13 12 7 17 13 21 9"/>'
      '<path d="M5 18V13l4 2 3-5 3 5 4-2v5"/><path d="M4 18h16"/></svg>';
  static const String _iconDiamond =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.16 1.16 21.69 21.69" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<polygon points="12 3 19 9 12 21 5 9"/><path d="M5 9h14"/>'
      '<path d="M12 3L9 9M12 3L15 9"/></svg>';
  static const String _iconSkull =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.46 1.21 21.08 21.08" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 3a8 8 0 0 0-8 8c0 2.6 1.3 4.6 3 5.7V19a1.5 1.5 0 0 0 1.5 1.5h7A1.5 1.5 0 0 0 17 19v-2.3c1.7-1.1 3-3.1 3-5.7a8 8 0 0 0-8-8Z"/>'
      '<circle cx="9" cy="11" r="1.8" fill="currentColor" stroke="none"/>'
      '<circle cx="15" cy="11" r="1.8" fill="currentColor" stroke="none"/>'
      '<path d="M11 15.2 12 13.5l1 1.7Z"/>'
      '<path d="M9.5 20.5v-2.5M12 20.5v-2.5M14.5 20.5v-2.5"/></svg>';
  static const String _iconStar =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0.55 -0.45 22.89 22.89" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<polygon points="12 2 14.8 8.2 21.5 9 16.5 13.4 17.9 20 12 16.8 6.1 20 7.5 13.4 2.5 9 9.2 8.2"/></svg>';
  static const String _iconLightning =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-0.05 -0.05 24.1 24.1" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<polygon points="13 2 6 12 11 12 9 22 18 10 13 10"/></svg>';
  static const String _iconHeart =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="2.36 3.36 19.28 19.28" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 21 C7 17 4 14 4 10 C4 7 6 5 9 5 C11 5 12 7 12 7 C12 7 13 5 15 5 C18 5 20 7 20 10 C20 14 17 17 12 21Z"/></svg>';
  static const String _iconMask =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="2.36 2.36 19.28 19.28" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 4c-4.4 0-8 1.8-8 4v3c0 4.6 3.6 8.6 8 9 c4.4-.4 8-4.4 8-9V8c0-2.2-3.6-4-8-4Z"/>'
      '<path d="M7.5 11c.9-1.2 2.7-1.2 3.5 0"/><path d="M13 11c.9-1.2 2.7-1.2 3.5 0"/>'
      '<path d="M8 14c1.4 1 2.6 1 4 0c1.4 1 2.6 1 4 0"/></svg>';
  static const String _iconRocket =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0.86 0.61 22.29 22.29" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 2.5c2.8 2 4.5 5.2 4.5 9 0 1.6-.3 3.1-.9 4.5H8.4A11 11 0 0 1 7.5 11.5c0-3.8 1.7-7 4.5-9Z"/>'
      '<circle cx="12" cy="10" r="1.8"/><path d="M8.4 16 5.5 18l1.8.5L7.5 21l2-1.8"/>'
      '<path d="M15.6 16l2.9 2-1.8.5.2 2.5-2-1.8"/></svg>';
  static const String _iconShield =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.4 1.2 21.2 21.2" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 3l7 3v5c0 5-3.3 8.2-7 9.6C8.3 19.2 5 16 5 11V6l7-3Z"/>'
      '<path d="M12 5v13"/></svg>';
  static const String _iconFlame =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="2.96 1.46 18.07 18.07" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 3c3 3 5.5 5.6 5.5 9.5A5.5 5.5 0 0 1 6.5 12.5C6.5 9.5 9 7 12 3Z"/>'
      '<path d="M12 9c1.5 1.5 2.5 2.8 2.5 4.3A2.5 2.5 0 0 1 9.5 13c0-1 .6-2 2.5-4Z"/></svg>';
  static const String _iconSnowflake =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0.55 0.55 22.89 22.89" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.6" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<g transform="rotate(0 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>'
      '<g transform="rotate(60 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>'
      '<g transform="rotate(120 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>'
      '<g transform="rotate(180 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>'
      '<g transform="rotate(240 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>'
      '<g transform="rotate(300 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g></svg>';
  static const String _iconMoon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="2.56 2.38 19.06 19.06" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M20 13.5A8 8 0 1 1 10.5 4a6.5 6.5 0 0 0 9.5 9.5Z"/>'
      '<path d="M17 4.5 17.6 6 19 6.6 17.6 7.2 17 8.7 16.4 7.2 15 6.6 16.4 6Z" fill="currentColor" stroke="none"/></svg>';
  static const String _iconSun =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-0.05 -0.05 24.1 24.1" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<circle cx="12" cy="12" r="4"/>'
      '<path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1"/></svg>';
  static const String _iconLeaf =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="3.57 4.57 16.87 16.87" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M5 19c0-8 5-13 14-13 0 9-5 14-13 14-1 0-1-1-1-1Z"/>'
      '<path d="M5 19C8 15 12 12 16 10"/></svg>';
  static const String _iconMusic =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="2.66 2.41 18.67 18.67" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<circle cx="7" cy="17" r="2.5"/><circle cx="17" cy="15" r="2.5"/>'
      '<path d="M9.5 17V6l10-2v11"/><path d="M9.5 8.5 19.5 6.5"/></svg>';
  static const String _iconEye =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-0.05 -0.05 24.1 24.1" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M2 12s4-6.5 10-6.5S22 12 22 12s-4 6.5-10 6.5S2 12 2 12Z"/>'
      '<circle cx="12" cy="12" r="3"/>'
      '<circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/></svg>';
  static const String _iconAnchor =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.76 1.26 20.48 20.48" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<circle cx="12" cy="5" r="2"/><path d="M12 7v13"/><path d="M8 11h8"/>'
      '<path d="M5 13a7 7 0 0 0 14 0"/></svg>';
  static const String _iconGem =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="1.16 1.16 21.69 21.69" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M7 4h10l4 5-9 11L3 9Z"/><path d="M3 9h18M7 4 9 9l3 11 3-11 2-5"/></svg>';

  static const String _iconAuraGold = '$_svgHead'
      '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="5"/></svg>';
  static const String _iconRedacted = '$_svgHead'
      '<line x1="4" y1="8" x2="20" y2="8"/><line x1="4" y1="12" x2="16" y2="12"/>'
      '<line x1="4" y1="16" x2="18" y2="16"/></svg>';
  static const String _iconAuraNeon = '$_svgHead'
      '<rect x="6" y="6" width="12" height="12" rx="3"/>'
      '<path d="M3 9V5a2 2 0 0 1 2-2h4M21 9V5a2 2 0 0 0-2-2h-4M3 15v4a2 2 0 0 0 2 2h4M21 15v4a2 2 0 0 1-2 2h-4"/></svg>';
  static const String _iconAuraRainbow = '$_svgHead'
      '<path d="M12 4 19 17H5Z"/><path d="M2 10.5 9 12.4"/><path d="M13.4 12.6 21.5 10.2"/>'
      '<path d="M13.7 13.9 21.5 13.4"/><path d="M13.9 15.2 21.5 16.6"/>'
      '<path d="M14.1 16.4 20.5 19.4"/></svg>';
  static const String _iconFrost = '$_svgHead'
      '<rect x="4" y="6" width="16" height="12" rx="2"/>'
      '<path d="M12 8.5v7M9 10l6 3.5M15 10l-6 3.5"/></svg>';
  static const String _iconAuraPhoenix = '$_svgHead'
      '<path d="M12 6.2a1.7 1.7 0 0 1 1.7-1.7c0 .8-.3 1.4-.9 1.8"/>'
      '<path d="M12 6.8C9 4.2 5.4 4 3 5.8c2 .3 2.9 1.6 2.7 3.3 1.7-1.1 3.4-.8 4.5.8"/>'
      '<path d="M12 6.8C15 4.2 18.6 4 21 5.8c-2 .3-2.9 1.6-2.7 3.3-1.7-1.1-3.4-.8-4.5.8"/>'
      '<path d="M12 7v7"/>'
      '<path d="M12 14c-1.9 1.3-2.5 3.3-1.7 5.2.8-.6 1.2-1.1 1.7-2.1.5 1 .9 1.5 1.7 2.1.8-1.9.2-3.9-1.7-5.2z"/></svg>';
  static const String _iconAuraCosmic = '$_svgHead'
      '<circle cx="11" cy="12" r="4.5"/>'
      '<ellipse cx="11" cy="12" rx="9" ry="3" transform="rotate(-22 11 12)"/>'
      '<path d="M19 5.5 19.6 7.1 21.2 7.7 19.6 8.3 19 9.9 18.4 8.3 16.8 7.7 18.4 7.1Z" fill="currentColor" stroke="none"/>'
      '<circle cx="4.5" cy="6" r="0.7" fill="currentColor" stroke="none"/></svg>';
  static const String _iconHologram = '$_svgHead'
      '<path d="M5 5h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-7l-4 4v-4H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z"/>'
      '<path d="M8 9.5h8M8 12.5h5"/></svg>';

  static const String _iconGenesis =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-0.05 -0.3 24.1 24.1" '
      'width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" '
      'stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">'
      '<path d="M12 2.5 22 21H2Z"/></svg>';
  static const String _iconEclipse = '$_svgHead'
      '<circle cx="12" cy="12" r="8"/>'
      '<path d="M15 5.2a8 8 0 0 1 0 13.6 8 8 0 0 0 0-13.6Z" fill="currentColor" stroke="none"/></svg>';
  static const String _iconCrt = '$_svgHead'
      '<rect x="3" y="4" width="18" height="13" rx="2"/>'
      '<path d="M8 21h8M12 17v4"/><path d="M6 7.5h9M6 10.5h7M6 13.5h5"/></svg>';

  static const String _iconBundleStarter = '$_svgHead'
      '<path d="M4 8h16v3H4zM5 11h14v9H5zM12 8v12"/>'
      '<path d="M12 8C10 8 8 7 8 5.5S10 4 12 8ZM12 8c2 0 4-1 4-2.5S14 4 12 8Z"/></svg>';
  static const String _iconBundleLegendary = '$_svgHead'
      '<path d="M4 9h16v3H4zM5 12h14v8H5zM12 9v11"/><path d="M6 9 9 4l3 5 3-5 3 5"/></svg>';
  static const String _iconBundleEverything = '$_svgHead'
      '<path d="M3 8h18v3H3zM4 11h16v9H4zM12 8v12"/>'
      '<path d="M12 8C9.5 8 7 6.8 7 5S9.5 3 12 8ZM12 8c2.5 0 5-1.2 5-3S14.5 3 12 8Z"/>'
      '<path d="M9 14.5l1.5 1.5L9 17.5M15 14.5l-1.5 1.5 1.5 1.5"/></svg>';
}

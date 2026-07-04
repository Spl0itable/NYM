import 'package:flutter/material.dart';

/// A purchasable shop item. Mirrors the PWA catalog entry (`js/app.js`
/// `this.shopItems`, docs/specs/04 §3.1). `icon` is the inline SVG string used
/// by the web; on native we render it via `flutter_svg`.
class ShopItem {
  const ShopItem({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.type,
    required this.icon,
    this.tier,
    this.cssClass,
    this.maxSupply,
    this.startsAt,
    this.endsAt,
    this.bundle,
  });

  final String id;
  final String name;
  final String description;
  final int price;

  /// One of: `message-style`, `nickname-flair`, `supporter`, `cosmetic`,
  /// `bundle`.
  final String type;

  /// Inline SVG markup (the PWA `item.icon`).
  final String icon;

  /// `'legendary'` for legendary-tier items, else null.
  final String? tier;

  /// Cosmetic CSS class (e.g. `cosmetic-aura-gold`).
  final String? cssClass;

  final int? maxSupply;
  final int? startsAt;
  final int? endsAt;
  final List<String>? bundle;

  bool get isLegendary => tier == 'legendary';
}

/// Which shop tab a card belongs to.
enum ShopTab { styles, flair, special, limited, inventory }

extension ShopTabLabel on ShopTab {
  String get label {
    switch (this) {
      case ShopTab.styles:
        return 'Message Styles';
      case ShopTab.flair:
        return 'Nickname Flair';
      case ShopTab.special:
        return 'Special Items';
      case ShopTab.limited:
        return 'Limited & Bundles';
      case ShopTab.inventory:
        return 'My Items';
    }
  }
}

/// An item the user owns, persisted in the shop record.
/// (docs/specs/04 §3.3 `owned{...}`.)
class OwnedItem {
  const OwnedItem({
    required this.itemId,
    required this.timestamp,
    required this.amountSats,
    this.code,
    this.gift = false,
    this.edition,
    this.editionMax,
  });

  final String itemId;
  final int timestamp;
  final int amountSats;
  final String? code;
  final bool gift;
  final int? edition;
  final int? editionMax;

  Map<String, dynamic> toJson() => {
        'at': timestamp,
        'amountSats': amountSats,
        if (code != null) 'code': code,
        'gift': gift,
        if (edition != null) 'edition': edition,
        if (editionMax != null) 'editionMax': editionMax,
      };

  factory OwnedItem.fromJson(String itemId, Map<String, dynamic> j) =>
      OwnedItem(
        itemId: itemId,
        timestamp: (j['at'] as num?)?.toInt() ?? 0,
        amountSats: (j['amountSats'] as num?)?.toInt() ?? 0,
        code: j['code'] as String?,
        gift: j['gift'] == true,
        edition: (j['edition'] as num?)?.toInt(),
        editionMax: (j['editionMax'] as num?)?.toInt(),
      );
}

/// The user's currently-active cosmetics (docs/specs/04 §3.3 `active{...}`).
/// Only one [style] and one [flair] may be active at a time; multiple
/// [cosmetics] are allowed.
class ActiveItems {
  const ActiveItems({
    this.style,
    this.flair = const [],
    this.cosmetics = const [],
    this.supporter = false,
    this.editions = const {},
  });

  final String? style;
  final List<String> flair;
  final List<String> cosmetics;
  final bool supporter;
  final Map<String, int> editions;

  ActiveItems copyWith({
    String? style,
    bool clearStyle = false,
    List<String>? flair,
    List<String>? cosmetics,
    bool? supporter,
    Map<String, int>? editions,
  }) =>
      ActiveItems(
        style: clearStyle ? null : (style ?? this.style),
        flair: flair ?? this.flair,
        cosmetics: cosmetics ?? this.cosmetics,
        supporter: supporter ?? this.supporter,
        editions: editions ?? this.editions,
      );

  Map<String, dynamic> toJson() => {
        'style': style,
        'flair': flair,
        'cosmetics': cosmetics,
        'supporter': supporter,
        'editions': editions,
      };

  factory ActiveItems.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ActiveItems();
    return ActiveItems(
      style: j['style'] as String?,
      flair: (j['flair'] as List?)?.cast<String>() ?? const [],
      cosmetics: (j['cosmetics'] as List?)?.cast<String>() ?? const [],
      supporter: j['supporter'] == true,
      editions: (j['editions'] as Map?)?.map(
            (k, v) => MapEntry(k as String, (v as num).toInt()),
          ) ??
          const {},
    );
  }
}

/// The per-style text colour + glow used to render the cosmetic preview,
/// ported from `css/styles-features.css` (`.message.style-X .message-content`).
/// Faithful subset: primary colour and glow; gradient styles use [gradient].
class MessageStyleVisual {
  const MessageStyleVisual({
    required this.color,
    this.glow,
    this.gradient,
    this.monospace = false,
    this.glyphShadows,
    this.contentBackground,
  });

  final Color color;
  final Color? glow;
  final List<Color>? gradient;
  final bool monospace;

  /// Explicit multi-offset glyph shadows for styles whose look is a layered
  /// `text-shadow` rather than a single soft glow — the glitch chromatic-split
  /// (`-2px #f00 / +2px #0ff`, `styles-features.css:625-628`). When set these
  /// replace the single [glow]-derived shadow in the preview bubble.
  final List<Shadow>? glyphShadows;

  /// Translucent `.message-content { background-color }` painted behind the
  /// text by the styles that have one (satoshi / eclipse / crt). Mirrors the
  /// verbatim alpha from `css/styles-features.css`; null = no background.
  final Color? contentBackground;
}

/// Cosmetic aura visual: border + glow colour (from `.message.cosmetic-X`).
///
/// [boxShadows] are the exact `box-shadow` layers from `.message.cosmetic-X`
/// (inset ring + outer glow) so the preview bubble matches the rendered
/// message. [borderLeft] is the gold/cyan `border-left` accent some auras add.
/// [ringGradient]/[sheenGradient] flag the legendary prism/hologram treatments
/// so the preview can paint a conic ring / holographic sheen rather than a flat
/// fill.
class CosmeticVisual {
  const CosmeticVisual({
    required this.accent,
    this.gradient,
    this.boxShadows,
    this.borderLeft,
    this.ringGradient,
    this.sheenGradient,
  });

  final Color accent;
  final List<Color>? gradient;
  final List<BoxShadow>? boxShadows;
  final Color? borderLeft;

  /// The 8-stop conic prism ring (`cosmetic-aura-rainbow`); when set the preview
  /// paints a [SweepGradient] border ring instead of a flat gradient fill.
  final List<Color>? ringGradient;

  /// The holographic multi-colour sheen (`cosmetic-bubble-hologram`); when set
  /// the preview layers a screen-blended gradient sheen over the bubble.
  final List<Color>? sheenGradient;
}

/// The availability of a limited-drop item, computed from its
/// `startsAt`/`endsAt`/`maxSupply` + live remaining supply
/// (`shop.js:_shopItemAvailability`).
enum ShopAvailabilityState { available, soon, ended, soldout }

/// A resolved availability `{state, label}` for a limited item — the supply
/// badge text + colour tier (`shop.js:813-830`).
class ShopAvailability {
  const ShopAvailability(this.state, this.label);

  final ShopAvailabilityState state;
  final String label;

  bool get isAvailable => state == ShopAvailabilityState.available;
}

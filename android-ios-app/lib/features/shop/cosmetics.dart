import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'shop_catalog.dart';
import 'shop_controller.dart';
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
  const UserCosmetics({this.styleId, this.flairId, this.supporter = false});

  /// Active message-style item id (e.g. `style-satoshi`), or null.
  final String? styleId;

  /// Active nickname-flair item id (e.g. `flair-crown`), or null.
  final String? flairId;

  /// True when the user owns + has the supporter badge active.
  final bool supporter;

  bool get isEmpty => styleId == null && flairId == null && !supporter;
  bool get isNotEmpty => !isEmpty;

  static const UserCosmetics none = UserCosmetics();
}

/// Resolves the [UserCosmetics] for [pubkey]. Reads `shopControllerProvider` for
/// the self pubkey and `usersProvider` for others. Pure with respect to its
/// inputs (no side effects), so it can be called from `build`.
UserCosmetics resolveCosmetics(WidgetRef ref, String pubkey) {
  final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    final active = ref.read(shopControllerProvider).active;
    return UserCosmetics(
      styleId: active.style,
      flairId: active.flair.isNotEmpty ? active.flair.last : null,
      supporter: active.supporter,
    );
  }
  final user = ref.read(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
}

/// Builds [UserCosmetics] from a [User]'s presence-broadcast cosmetic fields.
/// Exposed for tests and for the `watch`-based [userCosmeticsProvider].
UserCosmetics userCosmeticsFromUser(User? user) {
  if (user == null) return UserCosmetics.none;
  return UserCosmetics(
    styleId: (user.shopStyle != null && user.shopStyle!.isNotEmpty)
        ? user.shopStyle
        : null,
    flairId: (user.shopFlair != null && user.shopFlair!.isNotEmpty)
        ? user.shopFlair
        : null,
    supporter: user.isSupporter,
  );
}

/// Family provider variant of [resolveCosmetics], so widgets can `watch` a
/// pubkey's cosmetics and rebuild when the self shop state or the user's
/// presence-broadcast cosmetics change.
final userCosmeticsProvider =
    Provider.family<UserCosmetics, String>((ref, pubkey) {
  final selfPubkey = ref.watch(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    final active = ref.watch(shopControllerProvider).active;
    return UserCosmetics(
      styleId: active.style,
      flairId: active.flair.isNotEmpty ? active.flair.last : null,
      supporter: active.supporter,
    );
  }
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
    this.flairSize = 16,
    this.supporterHeight = 16,
  });

  final UserCosmetics cosmetics;

  /// Genesis edition number to stamp on a numbered flair, if known.
  final int? edition;

  final double flairSize;
  final double supporterHeight;

  @override
  Widget build(BuildContext context) {
    final flairId = cosmetics.flairId;
    final supporter = cosmetics.supporter;
    if ((flairId == null || flairId.isEmpty) && !supporter) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (flairId != null && flairId.isNotEmpty)
          FlairBadge(flairId: flairId, edition: edition, size: flairSize),
        if (supporter) SupporterBadge(height: supporterHeight),
      ],
    );
  }
}

/// A faithful Flutter translation of a `.message.style-X` rule from
/// `css/styles-features.css`. Captures the parts we can render natively:
///
/// * [textColor] — the glyph colour (`.message-content { color }`).
/// * [glow] — the text-shadow glow colour (approximated as a [Shadow] on the
///   content text and as a soft box-shadow behind it).
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
    this.gradient,
    this.contentBackground,
    this.borderAccent,
    this.monospace = false,
  });

  final Color textColor;
  final Color? glow;
  final List<Color>? gradient;
  final Color? contentBackground;
  final Color? borderAccent;
  final bool monospace;

  /// The glyph [Shadow]s reproducing the CSS `text-shadow` glow.
  List<Shadow>? get textShadows =>
      glow != null ? [Shadow(color: glow!, blurRadius: 10)] : null;
}

/// Maps a message-style id to its [MessageStyleDecoration], or null for an
/// unknown id (or null). Pure. Sourced from the per-style `styleVisuals` table
/// (`shop_catalog.dart`, ported from `css/styles-features.css`).
MessageStyleDecoration? messageStyleDecoration(String? styleId) {
  if (styleId == null || styleId.isEmpty) return null;
  final v = ShopCatalog.styleVisuals[styleId];
  if (v == null) return null;
  return MessageStyleDecoration(
    textColor: v.color,
    glow: v.glow,
    gradient: v.gradient,
    contentBackground: _styleContentBackground[styleId],
    monospace: v.monospace,
  );
}

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
  glow: Color(0x40FFD700), // rgba(255,215,0,.25)
  contentBackground: Color(0x14FFD700), // ~rgba(255,215,0,.08) bubble wash
  borderAccent: Color(0xFFFFD700),
);

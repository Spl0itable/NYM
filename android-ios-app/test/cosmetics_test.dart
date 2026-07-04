import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/shop/cosmetics.dart';
import 'package:nym_bar/features/shop/shop_controller.dart';
import 'package:nym_bar/features/shop/shop_models.dart';
import 'package:nym_bar/features/shop/shop_widgets.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/api/storage_sync.dart' show ShopStatusActive;
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';

/// A controller whose identity is a fixed self pubkey, so `resolveCosmetics`
/// resolves the self branch deterministically.
class _IdentityController extends NostrController {
  _IdentityController(super.ref, this._selfPubkey);

  final String _selfPubkey;

  @override
  Identity? get identity =>
      Identity(pubkey: _selfPubkey, privkey: null, nym: 'me');
}

/// A shop controller seeded with a known active record (no persistence).
class _FakeShopController extends ShopController {
  _FakeShopController(super.kv, ActiveItems active) {
    state = ShopState(active: active);
  }
}

/// An other-users shop controller seeded with known D1 shop-status records (no
/// network), so `resolveCosmetics` resolves the non-self branch deterministically.
class _SeededOtherUsersShop extends OtherUsersShopController {
  _SeededOtherUsersShop(super.kv, Map<String, ShopStatusActive> seed) {
    state = seed;
  }
}

Message _msg({
  String pubkey = 'pkOther',
  String author = 'alice#abcd',
  bool isOwn = false,
}) {
  return Message(
    id: 'm1',
    author: author,
    pubkey: pubkey,
    content: 'hello world',
    createdAt: 1000,
    isOwn: isOwn,
    eventKind: 20000,
    geohash: 'u4pruyd',
  );
}

Future<ProviderContainer> _container(List<Override> overrides) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      ...overrides,
    ],
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selfPubkey = 'selfpk';

  group('resolveCosmetics', () {
    test('returns self active style/flair/supporter for the self pubkey',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        shopControllerProvider.overrideWith(
          (ref) => _FakeShopController(
            kv,
            const ActiveItems(
              style: 'style-satoshi',
              flair: ['flair-crown'],
              supporter: true,
            ),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), selfPubkey);
      expect(cos.styleId, 'style-satoshi');
      expect(cos.flairId, 'flair-crown');
      expect(cos.supporter, isTrue);
    });

    test('returns others cosmetics from the User fields', () async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'bob',
            shopStyle: 'style-neon',
            shopFlair: 'flair-diamond',
            isSupporter: true,
          ),
        }),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), 'pkOther');
      expect(cos.styleId, 'style-neon');
      expect(cos.flairId, 'flair-diamond');
      expect(cos.supporter, isTrue);
    });

    test('userCosmeticsFromUser is empty for a null/blank user', () {
      expect(userCosmeticsFromUser(null).isEmpty, isTrue);
      expect(
        userCosmeticsFromUser(User(pubkey: 'x')).isEmpty,
        isTrue,
      );
    });

    test('prefers the authoritative D1 shop-status over presence User fields',
        () async {
      const otherPk = 'pkother';
      final kv = await () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        return KeyValueStore.open();
      }();
      final container = ProviderContainer(overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        // Presence said neon/diamond, but the D1 record (authoritative) says
        // satoshi/crown — the D1 record must win (matches the PWA).
        usersProvider.overrideWithValue({
          otherPk: User(
            pubkey: otherPk,
            nym: 'bob',
            shopStyle: 'style-neon',
            shopFlair: 'flair-diamond',
          ),
        }),
        otherUsersShopProvider.overrideWith(
          (ref) => _SeededOtherUsersShop(kv, {
            otherPk: const ShopStatusActive(
              style: 'style-satoshi',
              flair: ['flair-crown'],
              supporter: true,
              cosmetics: ['cosmetic-frost'],
              editions: {'flair-genesis': 7},
            ),
          }),
        ),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), otherPk);
      expect(cos.styleId, 'style-satoshi', reason: 'D1 record wins');
      expect(cos.flairId, 'flair-crown');
      expect(cos.supporter, isTrue);
      expect(cos.cosmetics, ['cosmetic-frost']);
    });

    test('userCosmeticsFromStatus keeps the last flair + genesis edition', () {
      final cos = userCosmeticsFromStatus(const ShopStatusActive(
        flair: ['flair-crown', 'flair-genesis'],
        editions: {'flair-genesis': 42},
      ));
      expect(cos.flairId, 'flair-genesis');
      expect(cos.genesisEdition, 42);
    });
  });

  group('messageStyleDecoration', () {
    test('maps a known style id to a non-null decoration', () {
      final deco = messageStyleDecoration('style-satoshi');
      expect(deco, isNotNull);
      // satoshi's `.message-content` CONTAINER (bare body text) is white
      // (styles-features.css:550) — only the inner `> *` children + the shop
      // preview are the bold orange #f7931a (`:571`). So body = white, the
      // preview/child colour = orange, and the body is NOT bold.
      expect(deco!.textColor, const Color(0xFFFFFFFF));
      expect(deco.previewColorFor(bubble: false), const Color(0xFFF7931A));
      expect(deco.childColor, const Color(0xFFF7931A));
      expect(deco.bold, isFalse);
      // satoshi paints a translucent content background.
      expect(deco.contentBackground, isNotNull);
    });

    test('satoshi light-mode body uses the dim container colour, not the child',
        () {
      final light = messageStyleDecoration('style-satoshi', isLight: true)!;
      // body.light-mode container #7a5500 (themes:900) vs inner child #c47a15
      // (themes:905).
      expect(light.textColor, const Color(0xFF7A5500));
      expect(light.previewColorFor(bubble: false), const Color(0xFFC47A15));
    });

    test('maps aurora to a gradient decoration', () {
      final deco = messageStyleDecoration('style-aurora');
      expect(deco, isNotNull);
      expect(deco!.gradient, isNotNull);
      expect(deco.gradient!.length, greaterThanOrEqualTo(2));
    });

    test('returns null for unknown / none id', () {
      expect(messageStyleDecoration(null), isNull);
      expect(messageStyleDecoration(''), isNull);
      expect(messageStyleDecoration('style-does-not-exist'), isNull);
    });

    test('supporterStyleDecoration carries a gold accent + glow', () {
      expect(supporterStyleDecoration.textColor, const Color(0xFFFFD700));
      expect(supporterStyleDecoration.borderAccent, isNotNull);
      expect(supporterStyleDecoration.textShadows, isNotNull);
    });

    test('light mode swaps the bright dark colour for the PWA light tone + '
        'drops the glow', () {
      // style-neon: #FF00FF + glow (dark) → #990099, no glow (light).
      final dark = messageStyleDecoration('style-neon');
      final light = messageStyleDecoration('style-neon', isLight: true);
      expect(dark!.textColor, const Color(0xFFFF00FF));
      expect(dark.textShadows, isNotNull);
      expect(light!.textColor, const Color(0xFF990099));
      expect(light.textShadows, isNull, reason: 'light resets text-shadow');
    });

    test('aurora keeps a gradient in light mode (with the light stops)', () {
      final light = messageStyleDecoration('style-aurora', isLight: true);
      expect(light!.gradient, isNotNull);
      expect(light.gradient!.first, const Color(0xFF007766));
    });

    test('glitch keeps its chromatic split in light mode', () {
      final light = messageStyleDecoration('style-glitch', isLight: true);
      expect(light!.textColor, const Color(0xFF006600));
      // The red/cyan glyph offsets are not a glow, so light keeps them.
      expect(light.textShadows, isNotNull);
      expect(light.textShadows!.length, 2);
    });

    test('supporter light variant is darker gold with no glow', () {
      expect(supporterStyleDecorationLight.textColor, const Color(0xFF8A6D00));
      expect(supporterStyleDecorationLight.textShadows, isNull);
    });
  });

  group('message-style glow / colour parity', () {
    test('neon is a triple-layer 10/20/30px halo (not a single glow)', () {
      final s = messageStyleDecoration('style-neon')!.textShadows!;
      expect(s.map((e) => e.blurRadius).toList(), [10.0, 20.0, 30.0]);
      expect(s.every((e) => e.color == const Color(0xFFFF00FF)), isTrue);
    });

    test('matrix is a double 10/20px halo', () {
      final s = messageStyleDecoration('style-matrix')!.textShadows!;
      expect(s.map((e) => e.blurRadius).toList(), [10.0, 20.0]);
    });

    test('fire glow blur is 14px (the real CSS, not a uniform 10)', () {
      final s = messageStyleDecoration('style-fire')!.textShadows!;
      expect(s.single.blurRadius, 14.0);
    });

    test('vapor carries the second cyan glow layer', () {
      final s = messageStyleDecoration('style-vapor')!.textShadows!;
      expect(s.length, 2);
      expect(s[1].color, const Color(0x4D05D9E8)); // rgba(5,217,232,.3)
      expect(s[1].blurRadius, 14.0);
    });

    test('royal carries the second gold glow layer', () {
      final s = messageStyleDecoration('style-royal')!.textShadows!;
      expect(s.length, 2);
      expect(s[1].color, const Color(0x4DD4AF37)); // rgba(212,175,55,.3)
    });

    test('eclipse carries the 8+16px dual glow', () {
      final s = messageStyleDecoration('style-eclipse')!.textShadows!;
      expect(s.map((e) => e.blurRadius).toList(), [8.0, 16.0]);
    });

    test('most styles glow at 8px (ocean/gold/blood/circuit), not 10', () {
      for (final id in [
        'style-ocean',
        'style-gold',
        'style-blood',
        'style-circuit',
      ]) {
        expect(messageStyleDecoration(id)!.textShadows!.single.blurRadius, 8.0,
            reason: id);
      }
    });

    test('satoshi has NO glow on the message (preview-only) + body is not bold',
        () {
      final deco = messageStyleDecoration('style-satoshi')!;
      expect(deco.textShadows, isNull, reason: 'no text-shadow on satoshi body');
      // `font-weight: bold` lives on the inner `> *` children
      // (styles-features.css:572), NOT the `.message-content` container — so the
      // bare body text is NORMAL weight.
      expect(deco.bold, isFalse);
    });

    test('ghost glow has a 2px Y-offset and 16px blur', () {
      final s = messageStyleDecoration('style-ghost')!.textShadows!.single;
      expect(s.offset, const Offset(0, 2));
      expect(s.blurRadius, 16.0);
    });

    test('fire/ice paint a brighter glyph in BUBBLE than IRC', () {
      final fire = messageStyleDecoration('style-fire')!;
      expect(fire.textColorFor(bubble: false), const Color(0xFFFFAA00));
      expect(fire.textColorFor(bubble: true), const Color(0xFFFF6600));
      final ice = messageStyleDecoration('style-ice')!;
      expect(ice.textColorFor(bubble: false), const Color(0xFF00CCEE));
      expect(ice.textColorFor(bubble: true), const Color(0xFF00CCFF));
    });

    test('aurora gradient is the 4-stop wrap + a blue glow', () {
      final deco = messageStyleDecoration('style-aurora')!;
      expect(deco.gradient!.length, 4);
      expect(deco.gradient!.first, const Color(0xFF00FFD5));
      expect(deco.gradient!.last, const Color(0xFF00FFD5),
          reason: 'trailing #00ffd5 closes the cyan wrap');
      expect(deco.gradientGlow, isNotNull);
      expect(deco.gradientGlow!.color, const Color(0x4D5B8CFF));
    });

    test('light mode drops the bubble colour override + the multi-glow', () {
      final fireLight = messageStyleDecoration('style-fire', isLight: true)!;
      // Light uses the single light colour for both layouts (no bubble override).
      expect(fireLight.textColorFor(bubble: true), const Color(0xFFCC4400));
      expect(fireLight.textShadows, isNull);
    });

    test('light mode swaps the watermark fill for ghost/gold', () {
      final ghostDark = messageStyleDecoration('style-ghost')!.watermark!;
      final ghostLight =
          messageStyleDecoration('style-ghost', isLight: true)!.watermark!;
      expect(ghostDark.svg, contains('#ffffff'));
      expect(ghostLight.svg, contains('#223044'),
          reason: 'white ghosts → dark-blue on light');
      final goldLight =
          messageStyleDecoration('style-gold', isLight: true)!.watermark!;
      expect(goldLight.svg, contains('#a07a00'));
    });

    test('supporter IRC paints a gold gradient; bubble a flat .12 wash', () {
      expect(supporterStyleDecoration.backgroundGradient, isNotNull);
      expect(supporterStyleDecoration.backgroundGradient!.first,
          const Color(0x14FFD700)); // .08
      expect(supporterStyleDecoration.contentBackground,
          const Color(0x1FFFD700)); // .12 flat bubble
      // The supporter glow is now an 8px blur (was a uniform 10).
      expect(supporterStyleDecoration.textShadows!.single.blurRadius, 8.0);
    });
  });

  group('cosmetic aura parity', () {
    UserCosmetics withAura(String id) => UserCosmetics(cosmetics: [id]);

    test('gold differs between bubble (.55 ring / 12px) and IRC (.35 / 18px)',
        () {
      final gold = resolveCosmeticAuras(withAura('cosmetic-aura-gold')).single;
      expect(gold.insetColorFor(bubble: false), const Color(0x59FFD700)); // .35
      expect(gold.insetColorFor(bubble: true), const Color(0x8CFFD700)); // .55
      expect(gold.glowBlurFor(bubble: false), 18.0);
      expect(gold.glowBlurFor(bubble: true), 12.0);
      // gold paints its gradient as the bubble fill; neon/phoenix/cosmic don't.
      expect(gold.bubblePaintsGradient, isTrue);
    });

    test('neon/phoenix/cosmic carry an IRC gradient but DO NOT fill the bubble',
        () {
      for (final id in [
        'cosmetic-aura-neon',
        'cosmetic-aura-phoenix',
        'cosmetic-aura-cosmic',
      ]) {
        final a = resolveCosmeticAuras(withAura(id)).single;
        expect(a.gradient, isNotNull, reason: '$id IRC row gradient');
        expect(a.bubblePaintsGradient, isFalse, reason: '$id bubble box-shadow only');
      }
    });

    test('frost tiles its snowflakes edge-only', () {
      final frost = resolveCosmeticAuras(withAura('cosmetic-frost')).single;
      expect(frost.edgeWatermark, isTrue);
    });

    test('light gold uses the PWA #b8960a border + softened ring/glow', () {
      final goldLight = resolveCosmeticAuras(withAura('cosmetic-aura-gold'),
              isLight: true)
          .single;
      expect(goldLight.borderAccent, const Color(0xFFB8960A));
      expect(goldLight.insetColor, const Color(0x4DB48C00)); // rgba(180,140,0,.3)
      expect(goldLight.glowBlurFor(bubble: false), 12.0);
    });

    test('only GOLD resolves a distinct light variant; the rest keep dark', () {
      // The PWA ships a `body.light-mode` aura rule ONLY for gold
      // (styles-themes-responsive.css:923-931); every other aura/special has
      // no light override and must resolve its dark values in light mode.
      final goldDark = resolveCosmeticAuras(withAura('cosmetic-aura-gold')).single;
      final goldLight =
          resolveCosmeticAuras(withAura('cosmetic-aura-gold'), isLight: true)
              .single;
      final goldChanged = goldLight.insetColor != goldDark.insetColor ||
          goldLight.glowColor != goldDark.glowColor ||
          goldLight.borderAccent != goldDark.borderAccent;
      expect(goldChanged, isTrue,
          reason: 'gold carries the sole light-mode aura rule');
      for (final id in [
        'cosmetic-aura-neon',
        'cosmetic-aura-rainbow',
        'cosmetic-aura-phoenix',
        'cosmetic-aura-cosmic',
        'cosmetic-frost',
        'cosmetic-bubble-hologram',
      ]) {
        final dark = resolveCosmeticAuras(withAura(id)).single;
        final light = resolveCosmeticAuras(withAura(id), isLight: true).single;
        expect(light.insetColor, dark.insetColor,
            reason: '$id has no light-mode CSS rule');
        expect(light.glowColor, dark.glowColor,
            reason: '$id has no light-mode CSS rule');
        expect(light.borderAccent, dark.borderAccent,
            reason: '$id has no light-mode CSS rule');
      }
    });

    test('prism ring + hologram still flag the overlay painter', () {
      expect(resolveCosmeticAuras(withAura('cosmetic-aura-rainbow'))
          .single
          .prismRing, isTrue);
      expect(resolveCosmeticAuras(withAura('cosmetic-bubble-hologram'))
          .single
          .hologram, isTrue);
    });
  });

  group('MessageRow cosmetics rendering', () {
    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    Future<void> pump(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: MessageRow(
                message: _msg(),
                settings: const Settings(chatLayout: 'irc'),
                reactions: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders the flair badge glyph for an author with flair',
        (tester) async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'alice',
            shopFlair: 'flair-crown',
          ),
        }),
      ]);
      addTearDown(container.dispose);

      await pump(tester, container);

      // The flair badge widget is present (its SVG renders the crown glyph).
      expect(find.byType(MessageRow), findsOneWidget);
      final flair = tester
          .widgetList<FlairBadge>(find.byType(FlairBadge))
          .where((w) => w.flairId == 'flair-crown');
      expect(flair, isNotEmpty);
      // And it is wired through the cosmetics badge row.
      expect(
        find.byWidgetPredicate((w) =>
            w is CosmeticNymBadges && w.cosmetics.flairId == 'flair-crown'),
        findsOneWidget,
      );
    });

    testWidgets('renders the supporter badge for a supporter user',
        (tester) async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'alice',
            isSupporter: true,
          ),
        }),
      ]);
      addTearDown(container.dispose);

      await pump(tester, container);

      // SupporterBadge renders the "SUPPORTER" pill text.
      expect(find.text('SUPPORTER'), findsOneWidget);
    });

    // P0: the prism ring / holographic sheen must paint in IRC (previously the
    // overlay painter was bubble-only, so IRC rainbow/hologram showed just a glow).
    Future<void> pumpIrcCosmetic(
        WidgetTester tester, String cosmeticId) async {
      final kv = await () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        return KeyValueStore.open();
      }();
      final container = ProviderContainer(overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        otherUsersShopProvider.overrideWith(
          (ref) => _SeededOtherUsersShop(kv, {
            'pkother': ShopStatusActive(cosmetics: [cosmeticId]),
          }),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: MessageRow(
                message: _msg(pubkey: 'pkOther'),
                settings: const Settings(chatLayout: 'irc'),
                reactions: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder overlayFinder() => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CosmeticOverlayPainter);

    testWidgets('IRC rainbow paints the prism-ring overlay', (tester) async {
      await pumpIrcCosmetic(tester, 'cosmetic-aura-rainbow');
      expect(overlayFinder(), findsWidgets,
          reason: 'prism ring must render in IRC, not just a glow');
      final painter = tester
          .widgetList<CustomPaint>(overlayFinder())
          .map((w) => w.painter as CosmeticOverlayPainter)
          .first;
      expect(painter.aura.prismRing, isTrue);
      expect(painter.bubble, isFalse);
    });

    testWidgets('IRC hologram paints the sheen overlay', (tester) async {
      await pumpIrcCosmetic(tester, 'cosmetic-bubble-hologram');
      expect(overlayFinder(), findsWidgets);
      final painter = tester
          .widgetList<CustomPaint>(overlayFinder())
          .map((w) => w.painter as CosmeticOverlayPainter)
          .first;
      expect(painter.aura.hologram, isTrue);
    });

    testWidgets('IRC without a prism/hologram aura paints no overlay',
        (tester) async {
      await pumpIrcCosmetic(tester, 'cosmetic-aura-gold');
      expect(overlayFinder(), findsNothing,
          reason: 'gold is a row border/glow in IRC, not an overlay-painter aura');
    });
  });

  // The flair glyph is a path-only inline `<svg>`, and CSS `text-shadow` does
  // not shadow replaced inline-SVG paths — only `filter: drop-shadow` does. So
  // the `.flair-X` `text-shadow` halo is INERT in the PWA (painted for no flair,
  // in either mode); the only glow rendered is the `filter: drop-shadow` on the
  // bright star/flame/diamond/genesis flairs, which the `body.light-mode` rules
  // do NOT reset, so it is present in BOTH modes. Each glow copy is an
  // `ImageFiltered` layer behind the crisp glyph, so the layer count is the
  // drop-shadow count (0 for text-shadow-only flairs, both modes).
  group('FlairBadge glow (light vs dark, styles-features.css)', () {
    Future<void> pumpFlair(
      WidgetTester tester,
      String flairId,
      Brightness brightness,
    ) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: brightness,
        solidUi: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNymThemeData(colors),
          home: Scaffold(body: Center(child: FlairBadge(flairId: flairId))),
        ),
      );
      // `flutter_svg` rasterizes asynchronously; settle so the glyph copies for
      // the current theme are the only ones mounted (a bare `pump` can briefly
      // retain the previous pump's copies).
      await tester.pumpAndSettle();
    }

    // One `ShopSvgIcon` per glyph copy: the crisp icon plus one per glow copy.
    // So #glow copies == (#ShopSvgIcon - 1).
    int glowCopies(WidgetTester tester) =>
        tester.widgetList<ShopSvgIcon>(find.byType(ShopSvgIcon)).length - 1;

    testWidgets('crown (text-shadow only): no glow in either mode',
        (tester) async {
      // text-shadow is inert on a path SVG and crown has no drop-shadow, so the
      // crisp glyph paints with no halo in dark OR light.
      await pumpFlair(tester, 'flair-crown', Brightness.dark);
      expect(glowCopies(tester), 0);
      await pumpFlair(tester, 'flair-crown', Brightness.light);
      expect(glowCopies(tester), 0);
    });

    testWidgets('star (drop-shadow): drop-shadow renders in both modes',
        (tester) async {
      // Only the `filter: drop-shadow` glows the SVG; the inert text-shadow adds
      // nothing, and the drop-shadow survives `body.light-mode`.
      await pumpFlair(tester, 'flair-star', Brightness.dark);
      expect(glowCopies(tester), 1);
      await pumpFlair(tester, 'flair-star', Brightness.light);
      expect(glowCopies(tester), 1);
    });

    testWidgets('genesis (drop-shadow): drop-shadow renders in both modes',
        (tester) async {
      // The two genesis text-shadows are inert; only its single drop-shadow
      // glows, in both dark and light.
      await pumpFlair(tester, 'flair-genesis', Brightness.dark);
      expect(glowCopies(tester), 1);
      await pumpFlair(tester, 'flair-genesis', Brightness.light);
      expect(glowCopies(tester), 1);
    });
  });
}

/// Minimal [WidgetRef] shim wrapping a [ProviderContainer] so [resolveCosmetics]
/// (which only calls `ref.read`) can run outside a widget tree.
class _WidgetRefShim implements WidgetRef {
  _WidgetRefShim(this._container);
  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

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
  });

  group('messageStyleDecoration', () {
    test('maps a known style id to a non-null decoration', () {
      final deco = messageStyleDecoration('style-satoshi');
      expect(deco, isNotNull);
      expect(deco!.textColor, const Color(0xFFF7931A));
      // satoshi paints a translucent content background.
      expect(deco.contentBackground, isNotNull);
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/channels/channel_context_menu.dart';
import 'package:nym_bar/features/channels/channel_share.dart';
import 'package:nym_bar/features/polls/poll_create_modal.dart';
import 'package:nym_bar/features/pms/new_pm_modal.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/chat_pane.dart';

/// A fake [NostrController] that records `togglePin` calls instead of touching
/// the network/persistence layer.
class _FakeController extends NostrController {
  _FakeController(super.ref);
  final List<String> pinned = [];

  @override
  bool togglePin(String key) {
    pinned.add(key);
    return true;
  }
}

NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

void main() {
  group('channel share URL', () {
    test('builds …/#<channel>', () {
      expect(
          buildChannelShareUrl('bitcoin'), 'https://app.nymchat.app/#bitcoin');
      expect(buildChannelShareUrl('9q8y'), 'https://app.nymchat.app/#9q8y');
    });

    test('falls back to #nymchat for an empty channel', () {
      expect(buildChannelShareUrl(''), 'https://app.nymchat.app/#nymchat');
    });

    test('channelEntryShareUrl uses the entry key (geohash or name)', () {
      expect(
        channelEntryShareUrl(ChannelEntry(channel: '9q8y', geohash: '9q8y')),
        'https://app.nymchat.app/#9q8y',
      );
      expect(
        channelEntryShareUrl(ChannelEntry(channel: 'Dev')),
        'https://app.nymchat.app/#dev',
      );
    });
  });

  group('poll-create validation', () {
    test('requires a question and ≥2 non-empty options', () {
      // No question.
      expect(pollFormValid('', ['a', 'b']), isFalse);
      // Only one non-empty option.
      expect(pollFormValid('Q?', ['a', '']), isFalse);
      expect(pollFormValid('Q?', ['a']), isFalse);
      // Whitespace-only options don't count.
      expect(pollFormValid('Q?', ['a', '   ']), isFalse);
      // Valid.
      expect(pollFormValid('Q?', ['a', 'b']), isTrue);
      expect(pollFormValid('Q?', ['a', 'b', 'c']), isTrue);
    });
  });

  group('recipient resolution', () {
    test('resolves hex pubkey, npub, and nym', () {
      const hex =
          '11111111111111111111111111111111111111111111111111111111deadbeef';
      final users = {
        hex: _user(hex, 'satoshi#beef'),
      };
      // Bare hex.
      expect(resolveRecipientPubkey(hex, users), hex);
      // Nym with suffix.
      expect(resolveRecipientPubkey('satoshi#beef', users), hex);
      // Nym without suffix.
      expect(resolveRecipientPubkey('satoshi', users), hex);
      // Unknown.
      expect(resolveRecipientPubkey('nobody', users), isNull);
    });
  });

  group('channel context menu', () {
    testWidgets('normal channel lists exactly Favorite/Hide/Block (PWA parity)',
        (tester) async {
      late BuildContext ctx;
      late WidgetRef ref;
      await _pumpProbe(tester, (c, r) {
        ctx = c;
        ref = r;
      });

      final actions = buildChannelMenuActions(
        ctx,
        ref,
        ChannelEntry(channel: 'bitcoin'),
      );
      final labels = actions.map((a) => a.label).toList();
      // sidebar-sections.js _buildSidebarMenuItems: Favorite / Hide / Block only.
      expect(labels, contains('Favorite channel'));
      expect(labels, contains('Hide channel'));
      expect(labels, contains('Block channel'));
      expect(labels, isNot(contains('Share')));
      expect(labels, isNot(contains('Copy link')));
      expect(labels, isNot(contains('Leave channel')));
    });

    testWidgets('#nymchat returns an empty menu (PWA parity)',
        (tester) async {
      late BuildContext ctx;
      late WidgetRef ref;
      await _pumpProbe(tester, (c, r) {
        ctx = c;
        ref = r;
      });

      final actions = buildChannelMenuActions(
        ctx,
        ref,
        ChannelEntry(channel: kDefaultChannel),
      );
      // sidebar-sections.js returns [] for the default channel — no menu.
      expect(actions, isEmpty);
    });
  });

  group('chat header', () {
    testWidgets('renders title + favorite/share; favorite calls togglePin',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      _FakeController? fake;
      final colors = _testColors();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            keyValueStoreProvider.overrideWithValue(kv),
            nostrControllerProvider.overrideWith((ref) {
              return fake = _FakeController(ref);
            }),
          ],
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: const Scaffold(body: ChatPane()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Title for the seeded #nymchat channel.
      expect(find.text('#nymchat'), findsOneWidget);

      // Favorite (star) + share buttons are present.
      final favorite = find.byTooltip('#nymchat is always favorited');
      expect(favorite, findsOneWidget);
      expect(find.byTooltip('Share channel URL'), findsOneWidget);

      // Switch to a non-default channel so favorite is tappable.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatPane)),
      );
      container.read(appStateProvider.notifier).switchChannel('bitcoin');
      await tester.pumpAndSettle();

      final favBtn = find.byTooltip('Favorite channel');
      expect(favBtn, findsOneWidget);
      await tester.tap(favBtn);
      await tester.pumpAndSettle();

      expect(fake!.pinned, contains('bitcoin'));
    });
  });
}

User _user(String pubkey, String nym) => User(pubkey: pubkey, nym: nym);

/// Pumps a minimal widget that captures a [BuildContext] + [WidgetRef] under a
/// configured [ProviderScope]/theme so menu builders can read providers.
Future<void> _pumpProbe(
  WidgetTester tester,
  void Function(BuildContext, WidgetRef) capture,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final colors = _testColors();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              capture(context, ref);
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

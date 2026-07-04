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
          buildChannelShareUrl('bitcoin'), 'https://web.nymchat.app/#bitcoin');
      expect(buildChannelShareUrl('9q8y'), 'https://web.nymchat.app/#9q8y');
    });

    test('falls back to #nymchat for an empty channel', () {
      expect(buildChannelShareUrl(''), 'https://web.nymchat.app/#nymchat');
    });

    test('channelEntryShareUrl uses the entry key (geohash or name)', () {
      expect(
        channelEntryShareUrl(ChannelEntry(channel: '9q8y', geohash: '9q8y')),
        'https://web.nymchat.app/#9q8y',
      );
      expect(
        channelEntryShareUrl(ChannelEntry(channel: 'Dev')),
        'https://web.nymchat.app/#dev',
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

  // D1 activity discovery → store seeding (AppStateNotifier.applyChannelActivity),
  // the consumer the controller's `_discoverChannelActivity` feeds with the
  // channel-active / channel-active-named / channel-activity results.
  group('D1 channel activity seeding', () {
    const self = '0000000000000000000000000000000000000000000000000000000000001a2b';
    const nowSec = 1750000000; // fixed boot-era timestamp for deterministic `last`.

    test('discovered geohash channels register in the sidebar + last-activity',
        () {
      final n = AppStateNotifier()..goLive(self, 'you#1a2b');
      // Two discovered geohash cells with 24-bucket activity + exact last-seen.
      n.applyChannelActivity(
        {
          '9q8y': [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          'u4pr': [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        {'9q8y': nowSec, 'u4pr': nowSec - 3600},
        geohash: true,
      );
      final s = n.state;
      // Both surfaced as geohash channels (key == geohash).
      final byKey = {for (final c in s.channels) c.key: c};
      expect(byKey.containsKey('9q8y'), isTrue);
      expect(byKey.containsKey('u4pr'), isTrue);
      expect(byKey['9q8y']!.isGeohash, isTrue);
      // last-activity stored under the `#`-prefixed key in MS (seconds × 1000).
      expect(s.channelLastActivity['#9q8y'], nowSec * 1000);
      expect(s.channelLastActivity['#u4pr'], (nowSec - 3600) * 1000);
    });

    test('#nymchat is never re-added and the active view gets no unread floor',
        () {
      final n = AppStateNotifier()..goLive(self, 'you#1a2b');
      // The live store boots with #nymchat as the only channel + active view.
      expect(n.state.channels.map((c) => c.key), ['nymchat']);
      n.applyChannelActivity(
        {
          'nymchat': [5, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        {'nymchat': nowSec},
        geohash: true,
      );
      // Still exactly one #nymchat row (no duplicate), and because it's the
      // active view its unread stays 0 (the open channel is being read).
      expect(n.state.channels.where((c) => c.key == 'nymchat').length, 1);
      expect(n.state.unreadCounts['#nymchat'] ?? 0, 0);
      // last-activity still tracked for the sort.
      expect(n.state.channelLastActivity['#nymchat'], nowSec * 1000);
    });

    test('joined non-active channel gets an unread FLOOR from buckets', () {
      final n = AppStateNotifier()..goLive(self, 'you#1a2b');
      n.addChannel('9q8y', geohash: '9q8y'); // joined but not the active view
      // Floors seed ONLY from the spam-aware `channel-activity` pass
      // (`seedUnread: true`) — discovery passes (`channel-active*`) never
      // badge, mirroring channels.js:320 "Spam-aware activity feeds unread
      // floors only".
      n.applyChannelActivity(
        {
          // 3 + 2 = 5 messages across the active window.
          '9q8y': [3, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        {'9q8y': nowSec},
        geohash: true,
        seedUnread: true,
      );
      expect(n.state.unreadCounts['#9q8y'], 5);

      // A discovery pass (no seedUnread) must NOT badge.
      n.applyChannelActivity(
        {
          '9q8y': [9, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        const {},
        geohash: true,
      );
      expect(n.state.unreadCounts['#9q8y'], 5,
          reason: 'discovery passes never seed floors');

      // D1 is a floor: a smaller re-probe must NOT lower an existing badge.
      n.applyChannelActivity(
        {
          '9q8y': [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        const {},
        geohash: true,
        seedUnread: true,
      );
      expect(n.state.unreadCounts['#9q8y'], 5, reason: 'floor only ever raises');
    });

    test('blocked channels are neither surfaced nor seeded', () {
      final n = AppStateNotifier()..goLive(self, 'you#1a2b');
      n.blockChannel('spamcell'); // would need to be a real key; use a word
      n.applyChannelActivity(
        {
          'spamcell': [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        },
        {'spamcell': nowSec},
        geohash: false,
      );
      expect(n.state.channels.any((c) => c.key == 'spamcell'), isFalse);
      expect(n.state.unreadCounts.containsKey('#spamcell'), isFalse);
      expect(n.state.channelLastActivity.containsKey('#spamcell'), isFalse);
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

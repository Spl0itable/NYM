import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/settings/settings_screen.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

void main() {
  group('SettingsController setters persist + round-trip', () {
    late KeyValueStore kv;
    late SettingsController ctrl;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      kv = await KeyValueStore.open();
      ctrl = SettingsController(kv);
    });

    // Reloads a fresh Settings from the store to prove the value was persisted
    // under the correct key and parses back identically.
    Settings reload() => Settings.fromStore(kv);

    test('appearance setters', () {
      ctrl.setTheme(NymThemeKey.cyber);
      expect(kv.getString(StorageKeys.theme), 'cyber');
      expect(reload().theme, NymThemeKey.cyber);

      ctrl.setColorMode(ColorMode.dark);
      expect(kv.getString(StorageKeys.colorMode), 'dark');
      expect(reload().colorMode, ColorMode.dark);

      ctrl.setTransparencyEnabled(true);
      expect(reload().transparencyEnabled, true);

      ctrl.setChatLayout('irc');
      expect(reload().chatLayout, 'irc');

      ctrl.setChatViewMode('columns');
      expect(reload().chatViewMode, 'columns');

      ctrl.setColumnsWallpaper(true);
      expect(reload().columnsWallpaper, true);

      ctrl.setWallpaperType('circuit');
      expect(reload().wallpaperType, 'circuit');

      ctrl.setTextSize(22);
      expect(kv.getString(StorageKeys.textSize), '22');
      expect(reload().textSize, 22);

      // Text size clamps to 12..28.
      ctrl.setTextSize(99);
      expect(reload().textSize, 28);
      ctrl.setTextSize(2);
      expect(reload().textSize, 12);

      ctrl.setNickStyle('simple');
      expect(reload().nickStyle, 'simple');

      ctrl.setDateFormat('ymd');
      expect(reload().dateFormat, 'ymd');
    });

    test('privacy setters', () {
      ctrl.setKeypairMode('hardcore');
      expect(kv.getString(StorageKeys.keypairMode), 'hardcore');
      expect(kv.getBool(StorageKeys.randomKeypairPerSession), true);
      expect(ctrl.keypairMode, 'hardcore');

      ctrl.setKeypairMode('persistent');
      expect(kv.getBool(StorageKeys.randomKeypairPerSession), false);

      ctrl.setPowDifficulty(16);
      expect(kv.getString(StorageKeys.powDifficulty), '16');
      expect(ctrl.powDifficulty, 16);

      ctrl.setAcceptPMs('friends');
      expect(reload().acceptPMs, 'friends');

      ctrl.setAcceptCalls('disabled');
      expect(reload().acceptCalls, 'disabled');

      ctrl.setDmForwardSecrecy(true);
      expect(reload().dmForwardSecrecyEnabled, true);

      ctrl.setDmTtlSeconds(604800);
      expect(kv.getString(StorageKeys.dmTtlSeconds), '604800');
      expect(reload().dmTtlSeconds, 604800);

      ctrl.setReadReceiptsScope('pms');
      expect(reload().readReceiptsScope, 'pms');

      ctrl.setTypingIndicatorsScope('groups');
      expect(reload().typingIndicatorsScope, 'groups');

      ctrl.setShowStatus('friends');
      expect(reload().showStatus, 'friends');

      ctrl.setCachePMs(false);
      expect(reload().cachePMs, false);

      ctrl.setBlurImages('friends');
      expect(kv.getString(StorageKeys.imageBlur), 'friends');
      expect(ctrl.blurImages, 'friends');
    });

    test('messaging setters', () {
      ctrl.setTranslateLanguage('es');
      expect(reload().translateLanguage, 'es');

      ctrl.setSound('uhoh');
      expect(reload().sound, 'uhoh');

      ctrl.setAutoscroll(false);
      expect(reload().autoscroll, false);

      ctrl.setShowTimestamps(false);
      expect(reload().showTimestamps, false);

      ctrl.setTimeFormat('24hr');
      expect(reload().timeFormat, '24hr');
    });

    test('channels setters', () {
      ctrl.setGroupChatPMOnlyMode(true);
      expect(reload().groupChatPMOnlyMode, true);

      ctrl.setSortByProximity(true);
      expect(reload().sortByProximity, true);

      ctrl.setHideNonPinned(true);
      expect(kv.getBool(StorageKeys.hideNonPinned), true);
      expect(ctrl.hideNonPinned, true);
    });

    test('landing channel persists, reads back, and is a SYNCED setting', () {
      var synced = 0;
      ctrl.onSyncedChange = () => synced++;

      // Default: unset.
      expect(ctrl.pinnedLandingChannelJson, isNull);

      const json = '{"type":"geohash","geohash":"9q8y"}';
      ctrl.setPinnedLandingChannel(json);
      expect(kv.getString(StorageKeys.pinnedLandingChannel), json);
      expect(ctrl.pinnedLandingChannelJson, json);
      // It fires the synced-change hook (the PWA routes it through the
      // channels sync section + nostrSettingsSave, settings.js:21,116).
      expect(synced, 1);

      // A blank value clears the override (boot then defaults to nymchat).
      ctrl.setPinnedLandingChannel('   ');
      expect(kv.getString(StorageKeys.pinnedLandingChannel), isNull);
      expect(ctrl.pinnedLandingChannelJson, isNull);
      expect(synced, 2);
    });

    test('mobile gesture setters', () {
      ctrl.setGesturesEnabled(false);
      expect(reload().gesturesEnabled, false);

      ctrl.setSwipeLeftAction('zap');
      expect(reload().swipeLeftAction, 'zap');

      ctrl.setSwipeRightAction('copy');
      expect(reload().swipeRightAction, 'copy');

      ctrl.setSwipeThreshold(100);
      expect(kv.getString(StorageKeys.swipeThreshold), '100');
      expect(reload().swipeThreshold, 100);

      ctrl.setSwipeReactEmoji('🔥');
      expect(reload().swipeReactEmoji, '🔥');
    });

    test('data setters', () {
      ctrl.setLowDataMode(true);
      expect(reload().lowDataMode, true);
    });
  });

  testWidgets('SettingsScreen renders sections and toggles a control',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    // Phone-width viewport (<=768 logical px) so the mobile-only "Mobile
    // Gestures" section is rendered (it is width-gated like the PWA's
    // `.mobile-only` reveal `@media (max-width:768px)`).
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // All six section headers are present (uppercased).
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('PRIVACY & SECURITY'), findsOneWidget);
    expect(find.text('MESSAGING & DISPLAY'), findsOneWidget);
    expect(find.text('CHANNELS'), findsOneWidget);
    expect(find.text('MOBILE GESTURES'), findsOneWidget);
    expect(find.text('DATA & BACKUP'), findsOneWidget);

    // The header is shown.
    expect(find.text('SETTINGS'), findsOneWidget);

    // Toggle a control: tap the "Dark" segment of the color-mode group.
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    // It persisted to the store.
    expect(kv.getString(StorageKeys.colorMode), 'dark');
  });
}

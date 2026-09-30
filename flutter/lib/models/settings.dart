import 'package:flutter/material.dart';

import '../core/constants/storage_keys.dart';
import '../core/theme/nym_colors.dart';
import '../services/storage/key_value_store.dart';

/// Color-mode preference (`nym_color_mode`).
enum ColorMode { auto, light, dark }

/// Scope for read receipts, typing, status and image blur.
enum ScopeSetting { everywhere, friends, disabled }

/// App settings mirroring the PWA's `this.settings`; persisted one field per key.
@immutable
class Settings {
  const Settings({
    this.theme = NymThemeKey.bitchat,
    this.colorMode = ColorMode.auto,
    this.sound = 'beep',
    this.autoscroll = true,
    this.showTimestamps = true,
    this.sortByProximity = false,
    this.timeFormat = '12hr',
    this.dateFormat = 'default',
    this.dmForwardSecrecyEnabled = false,
    this.dmTtlSeconds = 86400,
    this.readReceiptsScope = 'everywhere',
    this.typingIndicatorsScope = 'everywhere',
    this.nickStyle = 'fancy',
    this.chatLayout = 'bubbles',
    this.chatViewMode = 'single',
    this.columnsWallpaper = false,
    this.threadsEnabled = true,
    this.lowDataMode = false,
    this.backgroundConnectivity = false,
    this.meshEnabled = true,
    this.textSize = 15,
    this.transparencyEnabled = false,
    this.groupChatPMOnlyMode = false,
    this.translateLanguage = '',
    this.uiLanguage = '',
    this.gesturesEnabled = true,
    this.swipeLeftAction = 'quote',
    this.swipeRightAction = 'translate',
    this.swipeThreshold = 60,
    this.swipeReactEmoji = '❤️',
    this.acceptPMs = 'enabled',
    this.acceptCalls = 'enabled',
    this.cachePMs = true,
    this.syncMLSHistory = true,
    this.showStatus = 'true',
    this.wallpaperType = 'geometric',
    this.notificationsEnabled = true,
    this.hideNonPinned = false,
    this.columnsResetTick = 0,
  });

  final NymThemeKey theme;
  final ColorMode colorMode;
  final String sound;
  final bool autoscroll;
  final bool showTimestamps;
  final bool sortByProximity;
  final String timeFormat; // '12hr' | '24hr'
  final String dateFormat;
  final bool dmForwardSecrecyEnabled;
  final int dmTtlSeconds;
  final String readReceiptsScope;
  final String typingIndicatorsScope;
  final String nickStyle; // 'fancy' | ...
  final String chatLayout; // 'bubbles' | 'irc'
  final String chatViewMode; // 'single' | 'columns'
  final bool columnsWallpaper;

  /// Message threads (default on); off shows the classic flat view.
  final bool threadsEnabled;
  final bool lowDataMode;

  /// Keep relays and the mesh alive in the background; opt-in because it costs battery.
  final bool backgroundConnectivity;

  /// Bluetooth mesh transport alongside the Nostr relays.
  final bool meshEnabled;
  final int textSize;
  final bool transparencyEnabled;
  final bool groupChatPMOnlyMode;
  final String translateLanguage;

  /// Static UI language code (empty means English).
  final String uiLanguage;

  final bool gesturesEnabled;
  final String swipeLeftAction;
  final String swipeRightAction;
  final int swipeThreshold;
  final String swipeReactEmoji;
  final String acceptPMs;
  final String acceptCalls;
  final bool cachePMs;
  final bool syncMLSHistory;
  final String showStatus; // 'true' | 'false' | 'friends'
  final String wallpaperType;
  final bool notificationsEnabled;

  /// Hide non-favorited channels from the sidebar; device-local, never synced.
  final bool hideNonPinned;

  /// Runtime-only counter bumped by `resetColumns()` so a mounted deck re-seeds; never persisted.
  final int columnsResetTick;

  /// Solid UI is on unless transparency is explicitly enabled.
  bool get solidUi => !transparencyEnabled;

  bool get useBubbles => chatLayout != 'irc';

  bool get useColumns => chatViewMode == 'columns';

  Brightness effectiveBrightness(Brightness platform) {
    switch (colorMode) {
      case ColorMode.light:
        return Brightness.light;
      case ColorMode.dark:
        return Brightness.dark;
      case ColorMode.auto:
        return platform;
    }
  }

  Settings copyWith({
    NymThemeKey? theme,
    ColorMode? colorMode,
    String? sound,
    bool? autoscroll,
    bool? showTimestamps,
    bool? sortByProximity,
    String? timeFormat,
    String? dateFormat,
    bool? dmForwardSecrecyEnabled,
    int? dmTtlSeconds,
    String? readReceiptsScope,
    String? typingIndicatorsScope,
    String? nickStyle,
    String? chatLayout,
    String? chatViewMode,
    bool? columnsWallpaper,
    bool? threadsEnabled,
    bool? lowDataMode,
    bool? backgroundConnectivity,
    bool? meshEnabled,
    int? textSize,
    bool? transparencyEnabled,
    bool? groupChatPMOnlyMode,
    String? translateLanguage,
    String? uiLanguage,
    bool? gesturesEnabled,
    String? swipeLeftAction,
    String? swipeRightAction,
    int? swipeThreshold,
    String? swipeReactEmoji,
    String? acceptPMs,
    String? acceptCalls,
    bool? cachePMs,
    bool? syncMLSHistory,
    String? showStatus,
    String? wallpaperType,
    bool? notificationsEnabled,
    bool? hideNonPinned,
    int? columnsResetTick,
  }) {
    return Settings(
      theme: theme ?? this.theme,
      colorMode: colorMode ?? this.colorMode,
      sound: sound ?? this.sound,
      autoscroll: autoscroll ?? this.autoscroll,
      showTimestamps: showTimestamps ?? this.showTimestamps,
      sortByProximity: sortByProximity ?? this.sortByProximity,
      timeFormat: timeFormat ?? this.timeFormat,
      dateFormat: dateFormat ?? this.dateFormat,
      dmForwardSecrecyEnabled:
          dmForwardSecrecyEnabled ?? this.dmForwardSecrecyEnabled,
      dmTtlSeconds: dmTtlSeconds ?? this.dmTtlSeconds,
      readReceiptsScope: readReceiptsScope ?? this.readReceiptsScope,
      typingIndicatorsScope:
          typingIndicatorsScope ?? this.typingIndicatorsScope,
      nickStyle: nickStyle ?? this.nickStyle,
      chatLayout: chatLayout ?? this.chatLayout,
      chatViewMode: chatViewMode ?? this.chatViewMode,
      columnsWallpaper: columnsWallpaper ?? this.columnsWallpaper,
      threadsEnabled: threadsEnabled ?? this.threadsEnabled,
      lowDataMode: lowDataMode ?? this.lowDataMode,
      backgroundConnectivity:
          backgroundConnectivity ?? this.backgroundConnectivity,
      meshEnabled: meshEnabled ?? this.meshEnabled,
      textSize: textSize ?? this.textSize,
      transparencyEnabled: transparencyEnabled ?? this.transparencyEnabled,
      groupChatPMOnlyMode: groupChatPMOnlyMode ?? this.groupChatPMOnlyMode,
      translateLanguage: translateLanguage ?? this.translateLanguage,
      uiLanguage: uiLanguage ?? this.uiLanguage,
      gesturesEnabled: gesturesEnabled ?? this.gesturesEnabled,
      swipeLeftAction: swipeLeftAction ?? this.swipeLeftAction,
      swipeRightAction: swipeRightAction ?? this.swipeRightAction,
      swipeThreshold: swipeThreshold ?? this.swipeThreshold,
      swipeReactEmoji: swipeReactEmoji ?? this.swipeReactEmoji,
      acceptPMs: acceptPMs ?? this.acceptPMs,
      acceptCalls: acceptCalls ?? this.acceptCalls,
      cachePMs: cachePMs ?? this.cachePMs,
      syncMLSHistory: syncMLSHistory ?? this.syncMLSHistory,
      showStatus: showStatus ?? this.showStatus,
      wallpaperType: wallpaperType ?? this.wallpaperType,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      hideNonPinned: hideNonPinned ?? this.hideNonPinned,
      columnsResetTick: columnsResetTick ?? this.columnsResetTick,
    );
  }

  /// The five valid indicator scopes (PWA `INDICATOR_SCOPES`).
  static const List<String> indicatorScopes = [
    'disabled',
    'pms',
    'groups',
    'pms-groups',
    'everywhere',
  ];

  /// Coerces a stored scope: legacy 'true'/'false' map to everywhere/disabled, else [fallback].
  static String normalizeIndicatorScope(String? value,
      {String fallback = 'pms-groups'}) {
    if (value == 'true') return 'everywhere';
    if (value == 'false') return 'disabled';
    if (value != null && indicatorScopes.contains(value)) return value;
    return fallback;
  }

  /// Loads settings from the store with PWA defaults and coercions.
  factory Settings.fromStore(KeyValueStore kv) {
    ColorMode parseColorMode(String? v) {
      switch (v) {
        case 'light':
          return ColorMode.light;
        case 'dark':
          return ColorMode.dark;
        default:
          return ColorMode.auto;
      }
    }

    var sound = kv.getString(StorageKeys.sound) ?? 'beep';
    if (sound == 'icq') sound = 'uhoh';
    if (sound == 'msn') sound = 'msnding';

    return Settings(
      theme: NymThemeKey.fromId(kv.getString(StorageKeys.theme)),
      colorMode: parseColorMode(kv.getString(StorageKeys.colorMode)),
      sound: sound,
      autoscroll: kv.getBool(StorageKeys.autoscroll, defaultValue: true),
      showTimestamps: kv.getBool(StorageKeys.timestamps, defaultValue: true),
      sortByProximity:
          kv.getBool(StorageKeys.sortProximity, defaultValue: false),
      timeFormat: kv.getString(StorageKeys.timeFormat) ?? '12hr',
      dateFormat: kv.getString(StorageKeys.dateFormat) ?? 'default',
      dmForwardSecrecyEnabled:
          kv.getBool(StorageKeys.dmFwdSecEnabled, defaultValue: false),
      dmTtlSeconds: kv.getInt(StorageKeys.dmTtlSeconds, defaultValue: 86400),
      // As the PWA: the fallback derives from the legacy enabled boolean.
      readReceiptsScope: normalizeIndicatorScope(
        kv.getString(StorageKeys.readReceiptsScope),
        fallback: kv.getString(StorageKeys.readReceiptsEnabled) == 'false'
            ? 'disabled'
            : 'everywhere',
      ),
      typingIndicatorsScope: normalizeIndicatorScope(
        kv.getString(StorageKeys.typingIndicatorsScope),
        fallback: kv.getString(StorageKeys.typingIndicatorsEnabled) == 'false'
            ? 'disabled'
            : 'everywhere',
      ),
      nickStyle: kv.getString(StorageKeys.nickStyle) ?? 'fancy',
      chatLayout: kv.getString(StorageKeys.chatLayout) ?? 'bubbles',
      chatViewMode: kv.getString(StorageKeys.chatViewMode) ?? 'single',
      columnsWallpaper:
          kv.getBool(StorageKeys.columnsWallpaper, defaultValue: false),
      threadsEnabled: kv.getBool(StorageKeys.threadsEnabled, defaultValue: true),
      lowDataMode: kv.getBool(StorageKeys.lowDataMode, defaultValue: false),
      backgroundConnectivity: kv.getBool(StorageKeys.backgroundConnectivity,
          defaultValue: false),
      // On by default; the radio only starts once Bluetooth permission is granted.
      meshEnabled: kv.getBool(StorageKeys.meshEnabled, defaultValue: true),
      textSize: kv.getInt(StorageKeys.textSize, defaultValue: 15),
      transparencyEnabled:
          kv.getBool(StorageKeys.transparencyEnabled, defaultValue: false),
      groupChatPMOnlyMode:
          kv.getBool(StorageKeys.groupchatPmOnlyMode, defaultValue: false),
      translateLanguage: kv.getString(StorageKeys.translateLanguage) ?? '',
      uiLanguage: kv.getString(StorageKeys.uiLanguage) ?? '',
      gesturesEnabled:
          kv.getBool(StorageKeys.gesturesEnabled, defaultValue: true),
      swipeLeftAction: kv.getString(StorageKeys.swipeLeftAction) ?? 'quote',
      swipeRightAction:
          kv.getString(StorageKeys.swipeRightAction) ?? 'translate',
      swipeThreshold: kv.getInt(StorageKeys.swipeThreshold, defaultValue: 60),
      swipeReactEmoji: kv.getString(StorageKeys.swipeReactEmoji) ?? '❤️',
      acceptPMs: kv.getString(StorageKeys.acceptPms) ?? 'enabled',
      acceptCalls: kv.getString(StorageKeys.acceptCalls) ?? 'enabled',
      cachePMs: kv.getBool(StorageKeys.cachePms, defaultValue: true),
      syncMLSHistory:
          kv.getBool(StorageKeys.syncMlsHistory, defaultValue: true),
      showStatus: kv.getString(StorageKeys.showStatus) ?? 'true',
      wallpaperType: kv.getString(StorageKeys.wallpaperType) ?? 'geometric',
      notificationsEnabled:
          (kv.getString(StorageKeys.notificationsEnabled) ?? 'true') != 'false',
      hideNonPinned: kv.getBool(StorageKeys.hideNonPinned, defaultValue: false),
    );
  }
}

/// A `:shortcode:` swipe-react value; the picker returns these as well as literal emoji.
final RegExp _swipeReactShortcodeRe = RegExp(r'^:[A-Za-z0-9_]{1,48}:$');

/// A literal emoji has no ASCII letters, digits or whitespace; ZWJ sequences still pass.
final RegExp _swipeReactTextishRe = RegExp(r'[A-Za-z0-9\s]');

bool isValidSwipeReactEmoji(String value) {
  if (value.isEmpty) return false;
  if (_swipeReactShortcodeRe.hasMatch(value)) return true;
  return value.length <= 16 && !_swipeReactTextishRe.hasMatch(value);
}

/// Synced swipe-react emoji applies only when [remoteTs] >= [localTs], so stale blobs can't revert a pick.
bool shouldApplySyncedSwipeReactEmoji({
  required String value,
  required int remoteTs,
  required int localTs,
}) {
  if (!isValidSwipeReactEmoji(value)) return false;
  return remoteTs >= localTs;
}

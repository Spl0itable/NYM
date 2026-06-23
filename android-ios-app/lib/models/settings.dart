import 'package:flutter/material.dart';

import '../core/constants/storage_keys.dart';
import '../core/theme/nym_colors.dart';
import '../services/storage/key_value_store.dart';

/// Color-mode preference (`nym_color_mode`).
enum ColorMode { auto, light, dark }

/// Scope choices used by read-receipts / typing / status / image-blur.
/// (`everywhere` | `friends` | `disabled`)
enum ScopeSetting { everywhere, friends, disabled }

/// Application settings, mirroring the PWA `this.settings` object
/// (docs/specs/01 §1.9). Immutable; persisted one field per localStorage key.
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
    this.lowDataMode = false,
    this.textSize = 15,
    this.transparencyEnabled = false,
    this.groupChatPMOnlyMode = false,
    this.translateLanguage = '',
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
  final bool lowDataMode;
  final int textSize;
  final bool transparencyEnabled;
  final bool groupChatPMOnlyMode;
  final String translateLanguage;
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

  /// solid-ui is ON unless transparency is explicitly enabled.
  bool get solidUi => !transparencyEnabled;

  bool get useBubbles => chatLayout != 'irc';

  bool get useColumns => chatViewMode == 'columns';

  /// Resolves the effective brightness given the platform brightness.
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
    bool? lowDataMode,
    int? textSize,
    bool? transparencyEnabled,
    bool? groupChatPMOnlyMode,
    String? translateLanguage,
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
      lowDataMode: lowDataMode ?? this.lowDataMode,
      textSize: textSize ?? this.textSize,
      transparencyEnabled: transparencyEnabled ?? this.transparencyEnabled,
      groupChatPMOnlyMode: groupChatPMOnlyMode ?? this.groupChatPMOnlyMode,
      translateLanguage: translateLanguage ?? this.translateLanguage,
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
    );
  }

  /// Loads settings from the key/value store, applying PWA defaults/coercions.
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

    // Legacy sound aliases.
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
      readReceiptsScope:
          kv.getString(StorageKeys.readReceiptsScope) ?? 'everywhere',
      typingIndicatorsScope:
          kv.getString(StorageKeys.typingIndicatorsScope) ?? 'everywhere',
      nickStyle: kv.getString(StorageKeys.nickStyle) ?? 'fancy',
      chatLayout: kv.getString(StorageKeys.chatLayout) ?? 'bubbles',
      chatViewMode: kv.getString(StorageKeys.chatViewMode) ?? 'single',
      columnsWallpaper:
          kv.getBool(StorageKeys.columnsWallpaper, defaultValue: false),
      lowDataMode: kv.getBool(StorageKeys.lowDataMode, defaultValue: false),
      textSize: kv.getInt(StorageKeys.textSize, defaultValue: 15),
      transparencyEnabled:
          kv.getBool(StorageKeys.transparencyEnabled, defaultValue: false),
      groupChatPMOnlyMode:
          kv.getBool(StorageKeys.groupchatPmOnlyMode, defaultValue: false),
      translateLanguage: kv.getString(StorageKeys.translateLanguage) ?? '',
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
      notificationsEnabled: (kv.getString(StorageKeys.notificationsEnabled) ??
              'true') !=
          'false',
    );
  }
}

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
    this.threadsEnabled = true,
    this.lowDataMode = false,
    this.backgroundConnectivity = false,
    this.meshEnabled = true,
    this.textSize = 15,
    this.transparencyEnabled = false,
    this.groupChatPMOnlyMode = false,
    this.translateLanguage = '',
    this.uiLanguage = '',
    this.autoTranslate = false,
    this.autoTranslateChannels = true,
    this.autoTranslatePMs = true,
    this.autoTranslateGroups = true,
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

  /// Slack-style message threads (default ON). When disabled the app shows the
  /// classic flat view: replies render inline and no thread affordances appear.
  final bool threadsEnabled;
  final bool lowDataMode;

  /// When true, the app asks the OS to keep the Nostr relay sockets and the
  /// Bluetooth mesh radio alive while it is backgrounded, instead of letting
  /// every connection drop the moment the user leaves the app. Persisted as
  /// [StorageKeys.backgroundConnectivity]; costs battery, so it is opt-in.
  final bool backgroundConnectivity;

  /// When true, the Bluetooth mesh transport (bitchat-compatible offline mesh)
  /// is active alongside the Nostr relays. Persisted as [StorageKeys.meshEnabled].
  final bool meshEnabled;
  final int textSize;
  final bool transparencyEnabled;
  final bool groupChatPMOnlyMode;
  final String translateLanguage;

  /// The app's static-text UI language code (empty ⇒ English source shown as
  /// authored). See [StorageKeys.uiLanguage]; localized at runtime by
  /// `LocalizationService`.
  final String uiLanguage;

  /// Master switch: automatically translate incoming messages in the active
  /// conversation whose detected language differs from [translateLanguage].
  /// Requires a non-empty [translateLanguage] to have any effect.
  final bool autoTranslate;

  /// Per-conversation-type gates for [autoTranslate] (all default-on). A user
  /// can, e.g., auto-translate public channels but not their private chats.
  final bool autoTranslateChannels;
  final bool autoTranslatePMs;
  final bool autoTranslateGroups;

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

  /// Hide all non-favorited channels from the sidebar (`nym_hide_non_pinned`).
  /// Device-local-only (never cross-device synced). Held in state so the sidebar
  /// can `ref.watch(settingsProvider.select((s) => s.hideNonPinned))` and react
  /// live to the Channels → "Hide All Non-Favorited Channels" toggle.
  final bool hideNonPinned;

  /// Runtime-only counter bumped by `SettingsController.resetColumns()` so a
  /// mounted columns deck can observe the "Reset columns to defaults" action
  /// and re-seed live (PWA `cvResetColumns`, columns.js:363-381, tears down and
  /// re-seeds the deck immediately). Never persisted.
  final int columnsResetTick;

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
    bool? threadsEnabled,
    bool? lowDataMode,
    bool? backgroundConnectivity,
    bool? meshEnabled,
    int? textSize,
    bool? transparencyEnabled,
    bool? groupChatPMOnlyMode,
    String? translateLanguage,
    String? uiLanguage,
    bool? autoTranslate,
    bool? autoTranslateChannels,
    bool? autoTranslatePMs,
    bool? autoTranslateGroups,
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
      autoTranslate: autoTranslate ?? this.autoTranslate,
      autoTranslateChannels:
          autoTranslateChannels ?? this.autoTranslateChannels,
      autoTranslatePMs: autoTranslatePMs ?? this.autoTranslatePMs,
      autoTranslateGroups: autoTranslateGroups ?? this.autoTranslateGroups,
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

  /// The five valid indicator-scope values (PWA `INDICATOR_SCOPES`,
  /// settings.js:3).
  static const List<String> indicatorScopes = [
    'disabled',
    'pms',
    'groups',
    'pms-groups',
    'everywhere',
  ];

  /// Coerces a stored indicator-scope value to one of the five valid scopes
  /// (PWA `_normalizeIndicatorScope`, settings.js:27-32): legacy booleans map
  /// `'true'` → `'everywhere'` and `'false'` → `'disabled'`; anything else
  /// out-of-enum falls back to [fallback].
  static String normalizeIndicatorScope(String? value,
      {String fallback = 'pms-groups'}) {
    if (value == 'true') return 'everywhere';
    if (value == 'false') return 'disabled';
    if (value != null && indicatorScopes.contains(value)) return value;
    return fallback;
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
      // PWA loadSettings (settings.js:1105-1112): normalize the stored scope,
      // deriving the fallback from the legacy enabled boolean ('false' →
      // 'disabled', otherwise 'everywhere').
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
      // Mesh runs by default; the radio only actually starts once Bluetooth
      // permission is granted. Users who explicitly turn it off keep it off.
      meshEnabled: kv.getBool(StorageKeys.meshEnabled, defaultValue: true),
      textSize: kv.getInt(StorageKeys.textSize, defaultValue: 15),
      transparencyEnabled:
          kv.getBool(StorageKeys.transparencyEnabled, defaultValue: false),
      groupChatPMOnlyMode:
          kv.getBool(StorageKeys.groupchatPmOnlyMode, defaultValue: false),
      translateLanguage: kv.getString(StorageKeys.translateLanguage) ?? '',
      uiLanguage: kv.getString(StorageKeys.uiLanguage) ?? '',
      autoTranslate: kv.getBool(StorageKeys.autoTranslate, defaultValue: false),
      autoTranslateChannels:
          kv.getBool(StorageKeys.autoTranslateChannels, defaultValue: true),
      autoTranslatePMs:
          kv.getBool(StorageKeys.autoTranslatePms, defaultValue: true),
      autoTranslateGroups:
          kv.getBool(StorageKeys.autoTranslateGroups, defaultValue: true),
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

/// A swipe-react emoji is either a literal emoji or a `:shortcode:` naming a
/// custom emoji — the picker returns both (`EmojiPicker.onSelect`). Used to
/// validate the value arriving from a settings sync.
///
/// The previous rule was a flat 8-character cap, which rejected every
/// `:shortcode:` and the longer ZWJ sequences. A pick that failed here was
/// dropped silently, and the next publish from a device that had never chosen
/// one put the ❤️ default back over it — the "quick react keeps reverting"
/// bug.
final RegExp _swipeReactShortcodeRe = RegExp(r'^:[A-Za-z0-9_]{1,48}:$');

/// A literal emoji carries no ASCII letters, digits or whitespace, which is
/// what separates it from a short piece of text that happens to fit the length
/// bound. ZWJ (U+200D) and the variation selectors are not whitespace, so
/// sequences like 🏳️‍🌈 and 👨‍👩‍👧‍👦 still pass.
final RegExp _swipeReactTextishRe = RegExp(r'[A-Za-z0-9\s]');

bool isValidSwipeReactEmoji(String value) {
  if (value.isEmpty) return false;
  if (_swipeReactShortcodeRe.hasMatch(value)) return true;
  return value.length <= 16 && !_swipeReactTextishRe.hasMatch(value);
}

/// Whether a swipe-react emoji arriving from the settings sync may replace the
/// one this device holds.
///
/// The settings apply is otherwise unconditional and runs on every boot, so
/// without this a blob written BEFORE the user's pick — an older build's ❤️
/// default, or another device that never chose one — overwrote the choice at
/// every launch: the "quick react keeps reverting" bug.
///
/// [remoteTs] is the published `swipeReactEmojiTs` (0 when the payload predates
/// the stamp) and [localTs] is [StorageKeys.swipeReactEmojiTs] — 0 on a device
/// whose user never picked one, which is why anything still applies there.
/// Equal stamps apply so a device's own echo is a harmless no-op re-set.
bool shouldApplySyncedSwipeReactEmoji({
  required String value,
  required int remoteTs,
  required int localTs,
}) {
  if (!isValidSwipeReactEmoji(value)) return false;
  return remoteTs >= localTs;
}

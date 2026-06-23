import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/storage_keys.dart';
import '../core/theme/nym_colors.dart';
import '../core/theme/nym_theme.dart';
import '../models/settings.dart';
import '../services/storage/key_value_store.dart';

/// Provides the opened [KeyValueStore]. Overridden in `main()` with the
/// concrete instance (SharedPreferences must be opened asynchronously).
final keyValueStoreProvider = Provider<KeyValueStore>((ref) {
  throw UnimplementedError('keyValueStoreProvider must be overridden in main()');
});

/// Holds the live [Settings] and persists each change back to the store using
/// the same localStorage key names the PWA uses.
class SettingsController extends StateNotifier<Settings> {
  SettingsController(this._kv) : super(Settings.fromStore(_kv));

  final KeyValueStore _kv;

  /// Hook fired after any *synced* setting changes, so the [NostrController] can
  /// debounce a cross-device `settings-set` publish (the PWA's
  /// `nostrSettingsSave()` call peppered through every setter). Registered by the
  /// controller at boot; null otherwise (settings still persist locally). The
  /// device-local-only setters (keypair mode, image blur, pow, hide-non-pinned)
  /// deliberately do NOT fire it — they are never synced.
  void Function()? onSyncedChange;

  void _syncedChanged() {
    final cb = onSyncedChange;
    if (cb != null) cb();
  }

  void setTheme(NymThemeKey theme) {
    _kv.setString(StorageKeys.theme, theme.id);
    state = state.copyWith(theme: theme);
    _syncedChanged();
  }

  void setColorMode(ColorMode mode) {
    _kv.setString(StorageKeys.colorMode, mode.name);
    state = state.copyWith(colorMode: mode);
    _syncedChanged();
  }

  void setTransparencyEnabled(bool enabled) {
    _kv.setBool(StorageKeys.transparencyEnabled, enabled);
    state = state.copyWith(transparencyEnabled: enabled);
    _syncedChanged();
  }

  void setChatLayout(String layout) {
    _kv.setString(StorageKeys.chatLayout, layout);
    state = state.copyWith(chatLayout: layout);
    _syncedChanged();
  }

  void setChatViewMode(String mode) {
    _kv.setString(StorageKeys.chatViewMode, mode);
    state = state.copyWith(chatViewMode: mode);
    _syncedChanged();
  }

  /// Reset the saved column-view layout to defaults (PWA `cvResetColumns`):
  /// removes the persisted `nym_columns_layout` so the next column-view load
  /// re-seeds the default columns. The runtime re-render is handled by the
  /// columns feature when column view is active.
  void resetColumns() {
    _kv.remove(StorageKeys.columnsLayout);
  }

  void setTextSize(int size) {
    final clamped = size.clamp(12, 28);
    _kv.setInt(StorageKeys.textSize, clamped);
    state = state.copyWith(textSize: clamped);
    _syncedChanged();
  }

  void setTimeFormat(String fmt) {
    _kv.setString(StorageKeys.timeFormat, fmt);
    state = state.copyWith(timeFormat: fmt);
    _syncedChanged();
  }

  void setAutoscroll(bool v) {
    _kv.setBool(StorageKeys.autoscroll, v);
    state = state.copyWith(autoscroll: v);
    _syncedChanged();
  }

  void setShowTimestamps(bool v) {
    _kv.setBool(StorageKeys.timestamps, v);
    state = state.copyWith(showTimestamps: v);
    _syncedChanged();
  }

  void setSound(String sound) {
    _kv.setString(StorageKeys.sound, sound);
    state = state.copyWith(sound: sound);
    _syncedChanged();
  }

  void setWallpaperType(String type) {
    _kv.setString(StorageKeys.wallpaperType, type);
    state = state.copyWith(wallpaperType: type);
    _syncedChanged();
  }

  // --- Appearance (additional) ---------------------------------------------

  void setColumnsWallpaper(bool v) {
    _kv.setBool(StorageKeys.columnsWallpaper, v);
    state = state.copyWith(columnsWallpaper: v);
    _syncedChanged();
  }

  void setNickStyle(String style) {
    _kv.setString(StorageKeys.nickStyle, style);
    state = state.copyWith(nickStyle: style);
    _syncedChanged();
  }

  void setDateFormat(String fmt) {
    _kv.setString(StorageKeys.dateFormat, fmt);
    state = state.copyWith(dateFormat: fmt);
    _syncedChanged();
  }

  // --- Privacy & Security ---------------------------------------------------

  /// Keypair-per-session mode: 'persistent' | 'random' | 'hardcore'.
  /// Mirrors the PWA which writes both the legacy boolean flag and the mode.
  void setKeypairMode(String mode) {
    _kv.setString(StorageKeys.keypairMode, mode);
    _kv.setBool(
      StorageKeys.randomKeypairPerSession,
      mode == 'random' || mode == 'hardcore',
    );
  }

  String get keypairMode => _kv.getString(StorageKeys.keypairMode) ?? 'persistent';

  void setPowDifficulty(int bits) {
    _kv.setInt(StorageKeys.powDifficulty, bits);
  }

  int get powDifficulty =>
      _kv.getInt(StorageKeys.powDifficulty, defaultValue: 0);

  void setAcceptPMs(String v) {
    _kv.setString(StorageKeys.acceptPms, v);
    state = state.copyWith(acceptPMs: v);
    _syncedChanged();
  }

  void setAcceptCalls(String v) {
    _kv.setString(StorageKeys.acceptCalls, v);
    state = state.copyWith(acceptCalls: v);
    _syncedChanged();
  }

  void setDmForwardSecrecy(bool v) {
    _kv.setBool(StorageKeys.dmFwdSecEnabled, v);
    state = state.copyWith(dmForwardSecrecyEnabled: v);
    _syncedChanged();
  }

  void setDmTtlSeconds(int seconds) {
    _kv.setInt(StorageKeys.dmTtlSeconds, seconds);
    state = state.copyWith(dmTtlSeconds: seconds);
    _syncedChanged();
  }

  void setReadReceiptsScope(String scope) {
    _kv.setString(StorageKeys.readReceiptsScope, scope);
    state = state.copyWith(readReceiptsScope: scope);
    _syncedChanged();
  }

  void setTypingIndicatorsScope(String scope) {
    _kv.setString(StorageKeys.typingIndicatorsScope, scope);
    state = state.copyWith(typingIndicatorsScope: scope);
    _syncedChanged();
  }

  /// 'true' | 'friends' | 'false'.
  void setShowStatus(String v) {
    _kv.setString(StorageKeys.showStatus, v);
    state = state.copyWith(showStatus: v);
    _syncedChanged();
  }

  void setCachePMs(bool v) {
    _kv.setBool(StorageKeys.cachePms, v);
    state = state.copyWith(cachePMs: v);
    _syncedChanged();
  }

  /// Blur others' images: 'true' (blur) | 'friends' | 'false'.
  ///
  /// Mirrors the PWA `saveImageBlurSettings()`: always writes the global
  /// `nym_image_blur` key, and additionally the per-pubkey
  /// `nym_image_blur_<pubkey>` key when a [pubkey] is supplied.
  void setBlurImages(String v, {String? pubkey}) {
    _kv.setString(StorageKeys.imageBlur, v);
    if (pubkey != null && pubkey.isNotEmpty) {
      _kv.setString(StorageKeys.imageBlurFor(pubkey), v);
    }
  }

  String get blurImages => _kv.getString(StorageKeys.imageBlur) ?? 'true';

  // --- Messaging & Display --------------------------------------------------

  void setTranslateLanguage(String lang) {
    _kv.setString(StorageKeys.translateLanguage, lang);
    state = state.copyWith(translateLanguage: lang);
    _syncedChanged();
  }

  void setTimestamps(bool v) => setShowTimestamps(v);

  // --- Channels -------------------------------------------------------------

  void setGroupChatPMOnlyMode(bool v) {
    _kv.setBool(StorageKeys.groupchatPmOnlyMode, v);
    state = state.copyWith(groupChatPMOnlyMode: v);
    _syncedChanged();
  }

  void setSortByProximity(bool v) {
    _kv.setBool(StorageKeys.sortProximity, v);
    state = state.copyWith(sortByProximity: v);
    _syncedChanged();
  }

  void setHideNonPinned(bool v) {
    _kv.setBool(StorageKeys.hideNonPinned, v);
  }

  bool get hideNonPinned =>
      _kv.getBool(StorageKeys.hideNonPinned, defaultValue: false);

  // --- Mobile Gestures ------------------------------------------------------

  void setGesturesEnabled(bool v) {
    _kv.setBool(StorageKeys.gesturesEnabled, v);
    state = state.copyWith(gesturesEnabled: v);
    _syncedChanged();
  }

  void setSwipeLeftAction(String v) {
    _kv.setString(StorageKeys.swipeLeftAction, v);
    state = state.copyWith(swipeLeftAction: v);
    _syncedChanged();
  }

  void setSwipeRightAction(String v) {
    _kv.setString(StorageKeys.swipeRightAction, v);
    state = state.copyWith(swipeRightAction: v);
    _syncedChanged();
  }

  void setSwipeThreshold(int px) {
    _kv.setInt(StorageKeys.swipeThreshold, px);
    state = state.copyWith(swipeThreshold: px);
    _syncedChanged();
  }

  void setSwipeReactEmoji(String emoji) {
    _kv.setString(StorageKeys.swipeReactEmoji, emoji);
    state = state.copyWith(swipeReactEmoji: emoji);
    _syncedChanged();
  }

  // --- Data & Backup --------------------------------------------------------

  void setLowDataMode(bool v) {
    _kv.setBool(StorageKeys.lowDataMode, v);
    state = state.copyWith(lowDataMode: v);
    _syncedChanged();
  }

  /// Generic escape hatch for settings UI not yet given a typed setter.
  void update(Settings Function(Settings) fn) {
    state = fn(state);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsController, Settings>((ref) {
  return SettingsController(ref.watch(keyValueStoreProvider));
});

/// The current platform brightness (updated by the root widget from MediaQuery).
final platformBrightnessProvider =
    StateProvider<Brightness>((ref) => Brightness.dark);

/// Derived resolved color tokens for the active theme + mode.
final nymColorsProvider = Provider<NymColors>((ref) {
  final settings = ref.watch(settingsProvider);
  final platform = ref.watch(platformBrightnessProvider);
  final brightness = settings.effectiveBrightness(platform);
  return resolveNymColors(
    theme: settings.theme,
    brightness: brightness,
    solidUi: settings.solidUi,
  );
});

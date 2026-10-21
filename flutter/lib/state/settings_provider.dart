import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/storage_keys.dart';
import '../core/theme/nym_a11y.dart';
import '../core/theme/nym_colors.dart';
import '../core/theme/nym_theme.dart';
import '../models/settings.dart';
import '../services/storage/key_value_store.dart';
import '../services/attest/attest_badge.dart';
import '../services/filter/filter_packs.dart';
import '../features/sync/pref_stamps.dart';
import '../features/reactions/hover_actions.dart' as hover;
import '../core/crypto/pow.dart' show normalizePowDifficulty;
import 'app_state.dart' show appThreadsEnabled, setAppSpamFilter;
import 'app_state.dart' as globals show appPowFilterBits, appVerifiedFilter;

/// Provides the opened [KeyValueStore]; overridden in `main()` because SharedPreferences opens asynchronously.
final keyValueStoreProvider = Provider<KeyValueStore>((ref) {
  throw UnimplementedError(
      'keyValueStoreProvider must be overridden in main()');
});

/// Holds the live [Settings] and persists each change under the PWA's localStorage key names.
class SettingsController extends StateNotifier<Settings> {
  SettingsController(this._kv) : super(Settings.fromStore(_kv)) {
    _dropLegacyKeys();
  }

  void _dropLegacyKeys() {
    for (final key in StorageKeys.legacyAutoTranslateKeys) {
      if (_kv.contains(key)) unawaited(_kv.remove(key));
    }
  }

  final KeyValueStore _kv;

  /// Fired after a synced setting changes to debounce a cross-device publish; device-local setters never fire it.
  void Function()? onSyncedChange;

  void _syncedChanged() {
    final cb = onSyncedChange;
    if (cb != null) cb();
  }

  void notifySyncedChange() => _syncedChanged();

  void Function()? onPrefChanged;

  int _remoteDepth = 0;

  T applyingRemote<T>(T Function() body) {
    _remoteDepth++;
    try {
      return body();
    } finally {
      _remoteDepth--;
    }
  }

  bool get isApplyingRemote => _remoteDepth > 0;

  void _changed(List<String> names) {
    if (_remoteDepth > 0) {
      _syncedChanged();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final name in names) {
      PrefStamps.set(_kv, name, now);
    }
    final cb = onPrefChanged;
    if (cb != null) {
      cb();
    } else {
      _syncedChanged();
    }
  }

  /// Reloads first-run defaults after the panic path has wiped the store.
  void resetToDefaults() {
    state = Settings.fromStore(_kv);
  }

  void setTheme(NymThemeKey theme) {
    _kv.setString(StorageKeys.theme, theme.id);
    state = state.copyWith(theme: theme);
    _changed(const ['theme']);
  }

  void setColorMode(ColorMode mode) {
    _kv.setString(StorageKeys.colorMode, mode.name);
    state = state.copyWith(colorMode: mode);
    _changed(const ['colorMode']);
  }

  void setTransparencyEnabled(bool enabled) {
    _kv.setBool(StorageKeys.transparencyEnabled, enabled);
    state = state.copyWith(transparencyEnabled: enabled);
    _changed(const ['transparencyEnabled']);
  }

  void setChatLayout(String layout) {
    _kv.setString(StorageKeys.chatLayout, layout);
    state = state.copyWith(chatLayout: layout);
    _changed(const ['chatLayout']);
  }

  void setChatViewMode(String mode) {
    _kv.setString(StorageKeys.chatViewMode, mode);
    state = state.copyWith(chatViewMode: mode);
    _changed(const ['chatViewMode']);
  }

  /// Mirrored onto [appThreadsEnabled] so [visibleMessagesFor] can read it without a provider dependency.
  void setThreadsEnabled(bool v) {
    _kv.setBool(StorageKeys.threadsEnabled, v);
    appThreadsEnabled = v;
    state = state.copyWith(threadsEnabled: v);
    _changed(const ['threadsEnabled']);
  }

  void setChannelCounts(bool v) {
    _kv.setBool(StorageKeys.channelCounts, v);
    state = state.copyWith(channelCounts: v);
    _changed(const ['channelCounts']);
  }

  /// Clears the saved column layout and bumps [Settings.columnsResetTick] so a mounted deck re-seeds live.
  void resetColumns() {
    _kv.remove(StorageKeys.columnsLayout);
    state = state.copyWith(columnsResetTick: state.columnsResetTick + 1);
    // Synced in both branches, matching the PWA.
    _syncedChanged();
  }

  void setTextSize(int size) {
    final clamped = size.clamp(12, 28);
    _kv.setInt(StorageKeys.textSize, clamped);
    state = state.copyWith(textSize: clamped);
    _changed(const ['textSize']);
  }

  void setTimeFormat(String fmt) {
    _kv.setString(StorageKeys.timeFormat, fmt);
    state = state.copyWith(timeFormat: fmt);
    _changed(const ['timeFormat']);
  }

  void setAutoscroll(bool v) {
    _kv.setBool(StorageKeys.autoscroll, v);
    state = state.copyWith(autoscroll: v);
    _changed(const ['autoscroll']);
  }

  void setMeshEnabled(bool v) {
    _kv.setBool(StorageKeys.meshEnabled, v);
    state = state.copyWith(meshEnabled: v);
    _syncedChanged();
  }

  void setShowTimestamps(bool v) {
    _kv.setBool(StorageKeys.timestamps, v);
    state = state.copyWith(showTimestamps: v);
    _changed(const ['showTimestamps']);
  }

  void setSound(String sound) {
    _kv.setString(StorageKeys.sound, sound);
    state = state.copyWith(sound: sound);
    _changed(const ['sound']);
  }

  void setWallpaperType(String type) {
    _kv.setString(StorageKeys.wallpaperType, type);
    // Preset wallpapers clear the custom URL so it neither lingers nor rides the settings sync.
    if (type != 'custom') {
      _kv.remove(StorageKeys.wallpaperCustomUrl);
    }
    state = state.copyWith(wallpaperType: type);
    _changed(const ['wallpaperType']);
  }

  void setColumnsWallpaper(bool v) {
    _kv.setBool(StorageKeys.columnsWallpaper, v);
    state = state.copyWith(columnsWallpaper: v);
    _changed(const ['columnsWallpaper']);
  }

  void setNickStyle(String style) {
    _kv.setString(StorageKeys.nickStyle, style);
    state = state.copyWith(nickStyle: style);
    _changed(const ['nickStyle']);
  }

  void setDateFormat(String fmt) {
    _kv.setString(StorageKeys.dateFormat, fmt);
    state = state.copyWith(dateFormat: fmt);
    _changed(const ['dateFormat']);
  }

  /// Applies the PWA's session-nsec side effects of a keypair-mode change; registered by the controller.
  Future<void> Function(String mode)? onKeypairModeChanged;

  /// Keypair-per-session mode: 'persistent' | 'random' | 'hardcore'.
  void setKeypairMode(String mode) {
    _kv.setString(StorageKeys.keypairMode, mode);
    if (mode == 'random' || mode == 'hardcore') {
      _kv.setBool(StorageKeys.randomKeypairPerSession, true);
    } else {
      _kv.remove(StorageKeys.randomKeypairPerSession);
    }
    final cb = onKeypairModeChanged;
    if (cb != null) cb(mode);
  }

  String get keypairMode =>
      _kv.getString(StorageKeys.keypairMode) ?? 'persistent';

  void setPowDifficulty(int bits) {
    _kv.setInt(StorageKeys.powDifficulty, bits);
    globals.appPowFilterBits = normalizePowDifficulty(bits);
    _changed(const ['powDifficulty']);
  }

  int get powDifficulty =>
      _kv.getInt(StorageKeys.powDifficulty, defaultValue: 0);

  /// Inbound verified-app filter: 'off', 'verified' or 'any'.
  void setAppVerifiedFilter(String mode) {
    _kv.setString(StorageKeys.appVerifiedFilter, normalizeAppVerifiedFilter(mode));
    globals.appVerifiedFilter = appVerifiedFilter;
    _changed(const ['appVerifiedFilter']);
  }

  String get appVerifiedFilter =>
      normalizeAppVerifiedFilter(_kv.getString(StorageKeys.appVerifiedFilter));

  void setFilterPacks(List<String> ids) {
    _kv.setString(StorageKeys.filterPacks,
        jsonEncode(ids.where(kFilterPackIds.contains).toList()));
    _changed(const ['filterPacks']);
  }

  List<String> get filterPacks {
    final raw = _kv.getString(StorageKeys.filterPacks);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map((e) => e.toString()).where(kFilterPackIds.contains).toList();
    } catch (_) {
      return const [];
    }
  }

  bool get spamFilterEnabled =>
      _kv.getBool(StorageKeys.spamFilterEnabled, defaultValue: true);

  set spamFilterEnabled(bool v) =>
      _kv.setBool(StorageKeys.spamFilterEnabled, v);

  /// When false, only the known-spam literals trip the filter.
  bool get spamFilterAggressive =>
      _kv.getBool(StorageKeys.spamFilterAggressive, defaultValue: true);

  set spamFilterAggressive(bool v) =>
      _kv.setBool(StorageKeys.spamFilterAggressive, v);

  void setSpamFilter({bool? enabled, bool? aggressive}) {
    if (enabled != null) _kv.setBool(StorageKeys.spamFilterEnabled, enabled);
    if (aggressive != null) {
      _kv.setBool(StorageKeys.spamFilterAggressive, aggressive);
    }
    setAppSpamFilter(
        enabled: spamFilterEnabled, aggressive: spamFilterAggressive);
    _changed(const ['spamFilter']);
  }

  void setAcceptPMs(String v) {
    _kv.setString(StorageKeys.acceptPms, v);
    state = state.copyWith(acceptPMs: v);
    _changed(const ['acceptPMs']);
  }

  void setAcceptCalls(String v) {
    _kv.setString(StorageKeys.acceptCalls, v);
    state = state.copyWith(acceptCalls: v);
    _changed(const ['acceptCalls']);
  }

  void setDmForwardSecrecy(bool v) {
    _kv.setBool(StorageKeys.dmFwdSecEnabled, v);
    state = state.copyWith(dmForwardSecrecyEnabled: v);
    _changed(const ['dmForwardSecrecyEnabled']);
  }

  void setDmTtlSeconds(int seconds) {
    _kv.setInt(StorageKeys.dmTtlSeconds, seconds);
    state = state.copyWith(dmTtlSeconds: seconds);
    _changed(const ['dmTTLSeconds']);
  }

  void setReadReceiptsScope(String scope) {
    _kv.setString(StorageKeys.readReceiptsScope, scope);
    state = state.copyWith(readReceiptsScope: scope);
    _changed(const ['readReceiptsScope']);
  }

  void setTypingIndicatorsScope(String scope) {
    _kv.setString(StorageKeys.typingIndicatorsScope, scope);
    state = state.copyWith(typingIndicatorsScope: scope);
    _changed(const ['typingIndicatorsScope']);
  }

  /// 'true' | 'friends' | 'false'.
  void setShowStatus(String v) {
    _kv.setString(StorageKeys.showStatus, v);
    state = state.copyWith(showStatus: v);
    _changed(const ['showStatus']);
  }

  void setCachePMs(bool v) {
    _kv.setBool(StorageKeys.cachePms, v);
    state = state.copyWith(cachePMs: v);
    _changed(const ['cachePMs']);
  }

  /// Blur others' images: 'true' | 'friends' | 'false'; also writes the per-pubkey key when [pubkey] is given.
  void setBlurImages(String v, {String? pubkey}) {
    _kv.setString(StorageKeys.imageBlur, v);
    if (pubkey != null && pubkey.isNotEmpty) {
      _kv.setString(StorageKeys.imageBlurFor(pubkey), v);
    }
    _changed(const ['blurOthersImages']);
  }

  String? activePubkey;

  /// Per-pubkey `nym_image_blur_<pubkey>` wins, then the global key, defaulting to 'true'.
  String get blurImages {
    final pk = activePubkey;
    if (pk != null && pk.isNotEmpty) {
      final perKey = _kv.getString(StorageKeys.imageBlurFor(pk));
      if (perKey != null) return perKey;
    }
    return _kv.getString(StorageKeys.imageBlur) ?? 'true';
  }

  void setTranslateLanguage(String lang) {
    _kv.setString(StorageKeys.translateLanguage, lang);
    state = state.copyWith(translateLanguage: lang);
    _changed(const ['translateLanguage']);
  }

  /// The app's UI language (empty means English); synced across devices.
  void setUiLanguage(String lang) {
    _kv.setString(StorageKeys.uiLanguage, lang);
    _kv.setBool(StorageKeys.uiLanguageChosen, true);
    // Defaults the translation target to the app language; English maps to Disabled ('').
    _kv.setString(StorageKeys.translateLanguage, lang);
    state = state.copyWith(uiLanguage: lang, translateLanguage: lang);
    _changed(const ['uiLanguage', 'translateLanguage']);
  }

  void setTimestamps(bool v) => setShowTimestamps(v);

  /// Fired only when the value changed, so the controller can flip the critical REQ's channel-mode gate.
  void Function(bool enabled)? onGroupChatPMOnlyModeChanged;

  void setGroupChatPMOnlyMode(bool v) {
    final changed = state.groupChatPMOnlyMode != v;
    _kv.setBool(StorageKeys.groupchatPmOnlyMode, v);
    state = state.copyWith(groupChatPMOnlyMode: v);
    if (changed) onGroupChatPMOnlyModeChanged?.call(v);
    _changed(const ['groupChatPMOnlyMode']);
  }

  void setSortByProximity(bool v) {
    _kv.setBool(StorageKeys.sortProximity, v);
    state = state.copyWith(sortByProximity: v);
    _changed(const ['sortByProximity']);
  }

  /// Persists the landing-channel JSON (blank clears it) and fires a synced change.
  void setPinnedLandingChannel(String json) {
    final v = json.trim();
    if (v.isEmpty) {
      _kv.remove(StorageKeys.pinnedLandingChannel);
    } else {
      _kv.setString(StorageKeys.pinnedLandingChannel, v);
    }
    _changed(const ['pinnedLandingChannel']);
  }

  /// The persisted landing-channel JSON, or null when unset.
  String? get pinnedLandingChannelJson =>
      _kv.getString(StorageKeys.pinnedLandingChannel);

  void setHideNonPinned(bool v) {
    _kv.setBool(StorageKeys.hideNonPinned, v);
    state = state.copyWith(hideNonPinned: v);
    _changed(const ['hideNonPinned']);
  }

  bool get hideNonPinned => state.hideNonPinned;

  void setInfoPanelOpen(bool v) {
    _kv.setBool(StorageKeys.infoPanelOpen, v);
    state = state.copyWith(infoPanelOpen: v);
  }

  void setColorfulMessages(bool v, {int? syncedTs}) {
    _kv.setBool(StorageKeys.colorfulMessages, v);
    state = state.copyWith(colorfulMessages: v);
    _stampPref('colorfulMessages', syncedTs);
  }

  void setLargeTargets(bool v, {int? syncedTs}) {
    _kv.setBool(StorageKeys.largeTargets, v);
    state = state.copyWith(largeTargets: v);
    _stampPref('largeTargets', syncedTs);
  }

  void setHighContrast(bool v, {int? syncedTs}) {
    _kv.setBool(StorageKeys.highContrast, v);
    state = state.copyWith(highContrast: v);
    _stampPref('highContrast', syncedTs);
  }

  void setHidePreviews(bool v, {int? syncedTs}) {
    _kv.setBool(StorageKeys.hidePreviews, v);
    state = state.copyWith(hidePreviews: v);
    _stampPref('hidePreviews', syncedTs);
  }

  void notePrefChanged(String name) => _changed([name]);

  void _stampPref(String name, int? syncedTs) {
    if (syncedTs != null) {
      PrefStamps.set(_kv, name, syncedTs);
      return;
    }
    _changed([name]);
  }

  void setGesturesEnabled(bool v) {
    _kv.setBool(StorageKeys.gesturesEnabled, v);
    state = state.copyWith(gesturesEnabled: v);
    _changed(const ['gesturesEnabled']);
  }

  void setSwipeLeftAction(String v) {
    _kv.setString(StorageKeys.swipeLeftAction, v);
    state = state.copyWith(swipeLeftAction: v);
    _changed(const ['swipeLeftAction']);
  }

  void setSwipeRightAction(String v) {
    _kv.setString(StorageKeys.swipeRightAction, v);
    state = state.copyWith(swipeRightAction: v);
    _changed(const ['swipeRightAction']);
  }

  void setHoverActions(List<String> v) {
    final next = hover.normalizeHoverActions(v);
    _kv.setString(StorageKeys.hoverActions, jsonEncode(next));
    state = state.copyWith(hoverActions: next);
    _changed(const ['hoverActions']);
  }

  void pickHoverAction(int index, String id) =>
      setHoverActions(hover.pickHoverAction(state.hoverActions, index, id));

  void resetHoverActions() => setHoverActions(hover.kHoverActionDefaults);

  void setSwipeThreshold(int px) {
    _kv.setInt(StorageKeys.swipeThreshold, px);
    state = state.copyWith(swipeThreshold: px);
    _changed(const ['swipeThreshold']);
  }

  /// Stamps the pick time so stale synced blobs can't revert it; [remoteTs] keeps an inbound pick's original stamp.
  void setSwipeReactEmoji(String emoji, {int? remoteTs}) {
    _kv.setString(StorageKeys.swipeReactEmoji, emoji);
    _kv.setInt(
      StorageKeys.swipeReactEmojiTs,
      remoteTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    state = state.copyWith(swipeReactEmoji: emoji);
    _changed(const []);
  }

  /// Unix seconds of the last Quick-React pick, or 0 when never chosen.
  int get swipeReactEmojiTs =>
      _kv.getInt(StorageKeys.swipeReactEmojiTs, defaultValue: 0);

  void Function(bool enabled)? onLowDataModeChanged;

  void setLowDataMode(bool v) {
    _kv.setBool(StorageKeys.lowDataMode, v);
    state = state.copyWith(lowDataMode: v);
    onLowDataModeChanged?.call(v);
    _changed(const ['lowDataMode']);
  }

  /// Keeps relay sockets and the mesh running while backgrounded.
  void setBackgroundConnectivity(bool v) {
    _kv.setBool(StorageKeys.backgroundConnectivity, v);
    state = state.copyWith(backgroundConnectivity: v);
    _changed(const ['backgroundConnectivity']);
  }

  void update(Settings Function(Settings) fn) {
    state = fn(state);
  }

  /// Re-reads all `nym_*` keys from the store; does not fire [onSyncedChange] since it is not a user edit.
  void reloadFromStore() {
    final prev = state;
    state = Settings.fromStore(_kv);
    // Remote changes must still reach the relay layer.
    if (prev.lowDataMode != state.lowDataMode) {
      onLowDataModeChanged?.call(state.lowDataMode);
    }
    if (prev.groupChatPMOnlyMode != state.groupChatPMOnlyMode) {
      onGroupChatPMOnlyModeChanged?.call(state.groupChatPMOnlyMode);
    }
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsController, Settings>((ref) {
  return SettingsController(ref.watch(keyValueStoreProvider));
});

/// Updated by the root widget from MediaQuery.
final platformBrightnessProvider =
    StateProvider<Brightness>((ref) => Brightness.dark);

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

final nymA11yProvider = Provider<NymA11y>((ref) {
  final s = ref.watch(settingsProvider
      .select((x) => (t: x.largeTargets, c: x.highContrast)));
  return NymA11y(largeTargets: s.t, highContrast: s.c);
});

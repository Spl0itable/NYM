import 'package:flutter/material.dart' show Brightness;
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

  /// Public trigger for [onSyncedChange], for slices that persist a synced
  /// setting straight to the KV store outside this controller's setters (the
  /// columns deck's `nym_columns_layout` writes — `_cvSaveLayout`'s trailing
  /// `nostrSettingsSave()`, columns.js:993-994) — so they schedule the
  /// debounced cross-device publish without poking the hook field directly.
  void notifySyncedChange() => _syncedChanged();

  /// Reloads settings from the (now-wiped) store back to first-run defaults —
  /// the panic path's analogue of the PWA's page reload re-reading empty
  /// localStorage. Called by [NostrController.resetAfterPanic] after the KV
  /// store has been cleared, so theme/layout/etc. return to defaults without a
  /// process restart.
  void resetToDefaults() {
    state = Settings.fromStore(_kv);
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

  /// Reset the saved column-view layout to defaults (PWA `cvResetColumns`,
  /// columns.js:363-381): removes the persisted `nym_columns_layout` and bumps
  /// [Settings.columnsResetTick] so a mounted columns deck can observe the
  /// reset, tear down its live columns, and re-seed the defaults immediately —
  /// the PWA does this live (clears storage, re-seeds, re-focuses, re-syncs)
  /// rather than waiting for the next mount.
  void resetColumns() {
    _kv.remove(StorageKeys.columnsLayout);
    state = state.copyWith(columnsResetTick: state.columnsResetTick + 1);
    // SYNCED: the PWA pushes the cleared/re-seeded layout to the other devices
    // in BOTH branches — `nostrSettingsSave()` directly when columns are
    // inactive (columns.js:368) and via `_cvSeedDefaults` → `_cvSaveLayout` →
    // `nostrSettingsSave` when they are live (columns.js:374 → :994).
    _syncedChanged();
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
    // Selecting a non-custom wallpaper clears the stored custom URL — the PWA's
    // `saveWallpaper(type)` does `localStorage.removeItem('nym_wallpaper_custom_url')`
    // for every preset type (users.js:901-909), so the stale URL neither
    // lingers on-device nor keeps riding the outbound settings sync
    // (`wallpaperCustomUrl`, settings.js:124 syncs '' once cleared).
    if (type != 'custom') {
      _kv.remove(StorageKeys.wallpaperCustomUrl);
    }
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

  /// Hook fired after [setKeypairMode] persists the new mode, so the
  /// [NostrController] (which owns the [IdentityService]/secure store) can
  /// apply the PWA's save side effects (app.js:3873-3890): switching to
  /// random/hardcore removes the saved `nym_session_nsec`; switching to
  /// persistent saves the CURRENT session keypair's nsec when none is stored,
  /// so the in-use identity survives reload. Registered by the controller at
  /// boot; skipped for durable (nsec/extension/NIP-46) logins there, mirroring
  /// the PWA's `!isNostrLoggedIn()` gate.
  Future<void> Function(String mode)? onKeypairModeChanged;

  /// Keypair-per-session mode: 'persistent' | 'random' | 'hardcore'.
  /// Mirrors the PWA which writes both the legacy boolean flag and the mode
  /// (app.js:3875-3882: random/hardcore set the legacy flag, persistent
  /// removes it), then fires [onKeypairModeChanged] for the session-nsec
  /// side effects.
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

  String get keypairMode => _kv.getString(StorageKeys.keypairMode) ?? 'persistent';

  void setPowDifficulty(int bits) {
    _kv.setInt(StorageKeys.powDifficulty, bits);
  }

  int get powDifficulty =>
      _kv.getInt(StorageKeys.powDifficulty, defaultValue: 0);

  /// Heuristic content spam filter master switch (PWA `spamFilterEnabled`,
  /// app.js:559 — default **true**). Device-local (the PWA never syncs it and
  /// its settings modal has no toggle); persisted so a future UI can flip it.
  /// The [NostrController] mirrors this onto the [AppState] module flag
  /// [appSpamFilterEnabled] at boot so the pure [AppState.isMessageFiltered]
  /// gate can read it without a provider dependency.
  bool get spamFilterEnabled =>
      _kv.getBool(StorageKeys.spamFilterEnabled, defaultValue: true);

  set spamFilterEnabled(bool v) =>
      _kv.setBool(StorageKeys.spamFilterEnabled, v);

  /// Aggressive-heuristics sub-flag (PWA `spamFilterAggressive`, app.js:560 —
  /// default **true**). When false, only the two known-spam literals trip the
  /// filter; the gibberish/mixed-script/long-word scoring is skipped.
  bool get spamFilterAggressive =>
      _kv.getBool(StorageKeys.spamFilterAggressive, defaultValue: true);

  set spamFilterAggressive(bool v) =>
      _kv.setBool(StorageKeys.spamFilterAggressive, v);

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

  /// The active identity's pubkey, set by the [NostrController] at boot and on
  /// every identity change, so [blurImages] can resolve the per-pubkey blur
  /// key the way the PWA's `loadImageBlurSettings` does.
  String? activePubkey;

  /// PWA `loadImageBlurSettings` (settings.js:1139-1156): the per-pubkey
  /// `nym_image_blur_<pubkey>` key wins, then the global `nym_image_blur`,
  /// defaulting to blur ('true').
  String get blurImages {
    final pk = activePubkey;
    if (pk != null && pk.isNotEmpty) {
      final perKey = _kv.getString(StorageKeys.imageBlurFor(pk));
      if (perKey != null) return perKey;
    }
    return _kv.getString(StorageKeys.imageBlur) ?? 'true';
  }

  // --- Messaging & Display --------------------------------------------------

  void setTranslateLanguage(String lang) {
    _kv.setString(StorageKeys.translateLanguage, lang);
    state = state.copyWith(translateLanguage: lang);
    _syncedChanged();
  }

  void setTimestamps(bool v) => setShowTimestamps(v);

  // --- Channels -------------------------------------------------------------

  /// Hook fired after [setGroupChatPMOnlyMode] persists a CHANGED value, so
  /// the [NostrController] can flip the critical REQ's channelMode gate
  /// (relays.js:2488 `!this.settings.groupChatPMOnlyMode`; the PWA re-applies
  /// via `applyGroupChatPMOnlyMode` only when the value changed, app.js:3978).
  /// Registered by the controller at boot.
  void Function(bool enabled)? onGroupChatPMOnlyModeChanged;

  void setGroupChatPMOnlyMode(bool v) {
    final changed = state.groupChatPMOnlyMode != v;
    _kv.setBool(StorageKeys.groupchatPmOnlyMode, v);
    state = state.copyWith(groupChatPMOnlyMode: v);
    if (changed) onGroupChatPMOnlyModeChanged?.call(v);
    _syncedChanged();
  }

  void setSortByProximity(bool v) {
    _kv.setBool(StorageKeys.sortProximity, v);
    state = state.copyWith(sortByProximity: v);
    _syncedChanged();
  }

  /// Default landing channel (`nym_pinned_landing_channel`), persisted as the
  /// `{"type":"geohash","geohash":"…"}` JSON string the PWA stores
  /// (app.js:3899-3914). It is NOT a typed [Settings] field — it lives KV-only
  /// (the `LandingChannel` model in settings_helpers.dart) — so this writes the
  /// store directly. SYNCED: the PWA routes `pinnedLandingChannel` through the
  /// `channels` settings-sync section (settings.js:21,116), so this fires
  /// [_syncedChanged] like the other synced setters. The cross-device publish
  /// reads the value back via [pinnedLandingChannelJson].
  ///
  /// [json] must be the serialized choice (`LandingChannel.toJsonString()`); an
  /// empty/blank value clears the override (boot then falls back to the default
  /// `nymchat`). Use this from the settings UI in place of a bare KV write so a
  /// landing-channel change propagates to the user's other devices.
  void setPinnedLandingChannel(String json) {
    final v = json.trim();
    if (v.isEmpty) {
      _kv.remove(StorageKeys.pinnedLandingChannel);
    } else {
      _kv.setString(StorageKeys.pinnedLandingChannel, v);
    }
    _syncedChanged();
  }

  /// The persisted landing-channel JSON (`nym_pinned_landing_channel`), or null
  /// when unset (boot defaults to `nymchat`). Consumed by the cross-device
  /// settings publish so [StorageSync.settingsSet] can include it in the
  /// `channels` section payload (the PWA's `_buildSettingsPayload`,
  /// settings.js:116). Not part of the typed [Settings] state, so it is read
  /// straight from the store.
  String? get pinnedLandingChannelJson =>
      _kv.getString(StorageKeys.pinnedLandingChannel);

  /// Hide-all-non-favorited toggle. Device-local-only (the PWA never syncs it,
  /// so this deliberately does NOT call [_syncedChanged]), but it now lives in
  /// the [Settings] state so the sidebar can react via
  /// `ref.watch(settingsProvider.select((s) => s.hideNonPinned))`.
  void setHideNonPinned(bool v) {
    _kv.setBool(StorageKeys.hideNonPinned, v);
    state = state.copyWith(hideNonPinned: v);
  }

  bool get hideNonPinned => state.hideNonPinned;

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

  /// Hook fired after [setLowDataMode] persists the new value, so the
  /// [NostrController] can mirror it onto the live relay layer
  /// ([NostrService.setLowDataMode] — the PWA's `applyLowDataMode` call on
  /// every settings save, app.js:3989). Registered by the controller at boot.
  void Function(bool enabled)? onLowDataModeChanged;

  void setLowDataMode(bool v) {
    _kv.setBool(StorageKeys.lowDataMode, v);
    state = state.copyWith(lowDataMode: v);
    onLowDataModeChanged?.call(v);
    _syncedChanged();
  }

  /// Generic escape hatch for settings UI not yet given a typed setter.
  void update(Settings Function(Settings) fn) {
    state = fn(state);
  }

  /// Re-reads every `nym_*` settings key from the [KeyValueStore] back into the
  /// live [Settings] state. Used after an out-of-band write to the store — a
  /// settings reset / wipe (`resetAllSettings`) or a cross-device restore that
  /// mutated KV directly — so the in-memory state reflects the on-disk values
  /// without restarting the app. Mirrors the PWA's `loadSettings()` re-read.
  ///
  /// Does NOT fire [onSyncedChange]: this is a read-back of already-persisted
  /// values, not a user edit, so it must not trigger a cross-device publish (the
  /// PWA guards the same re-read with `_applyingRemoteSettings`).
  void reloadFromStore() {
    final prev = state;
    state = Settings.fromStore(_kv);
    // A remote/out-of-band change to these must still reach the relay layer —
    // the PWA's remote-settings apply calls applyLowDataMode /
    // applyGroupChatPMOnlyMode when the value CHANGED (app.js:6329-6346).
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

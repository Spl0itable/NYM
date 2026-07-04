import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../../core/constants/storage_keys.dart';
import '../../models/settings.dart';
import '../nostr/event_signer.dart';
import '../storage/key_value_store.dart';
import 'api_client.dart';
import 'api_config.dart';

/// Cross-device storage sync against the Cloudflare `/api/storage` worker
/// (`functions/api/storage.js`). Mirrors the PWA's three storage paths:
///
///  1. **Encrypted settings sync** — `settings-set`/`settings-get` with the
///     synced settings categories encrypted to self via NIP-44, keyed by the
///     real category embedded in the blob (`__cat`). Mirrors `settings.js`
///     `_saveSettingsBlobToD1` / `settingsLoadFromD1` (the section-blob form).
///  2. **D1-first profile mirror** — `profile-get` (public batch read) and
///     `profile-set` (own kind-0 mirror). Mirrors `nostr-core.js`
///     `_fetchProfilesFromD1` / `_saveProfileToD1`.
///  3. **PM gift-wrap archive** — `pm-put` (own inbox), `pm-deposit` (recipient
///     inbox), `pm-get` (restore). Mirrors `pms.js` `_archivePMEvent` /
///     `_depositPMEvent` / `pmRestoreFromD1` / `pmLoadOlderFromD1`.
///
/// Every call is lazy and failure-tolerant: the live host is unreachable from
/// some environments, so transport errors are swallowed (the PWA wraps every
/// path in `try/catch` and treats failures as best-effort). Construction does NO
/// network. The [ApiClient] + [EventSigner] are injected so tests can drive it
/// with a MockClient and a deterministic local key.
class StorageSync {
  StorageSync({
    required ApiClient api,
    required EventSigner signer,
    required String pubkey,
    required bool durableIdentity,
    KeyValueStore? kv,
  })  : _api = api,
        _signer = signer,
        _pubkey = pubkey.toLowerCase(),
        _durable = durableIdentity,
        _kv = kv;

  final ApiClient _api;
  final EventSigner _signer;
  final String _pubkey;

  /// The KV store the KV-backed synced prefs (moderation lists, pinned/hidden
  /// channels, emoji favorites, columns layout, …) are read from at publish
  /// time — the PWA reads the same values straight from `localStorage` /
  /// lazily-stored sets in `_buildSettingsPayload` (settings.js:91-165). Null
  /// (tests / legacy construction) restricts the payload to the typed
  /// [Settings] subset.
  final KeyValueStore? _kv;

  /// Lazily-opened fallback for [_kv]. Legacy construction (no injected store)
  /// would otherwise silently drop every KV-backed synced pref — columnsLayout,
  /// moderation lists, emoji favorites, `wallpaperCustomUrl`, PoW, keypair
  /// mode, … — publishing a payload far smaller than the PWA's
  /// `_buildSettingsPayload` (settings.js:91-165) and stomping another device's
  /// synced `columnsLayout` with `[]`. [KeyValueStore.open] wraps the same
  /// SharedPreferences singleton the app's `keyValueStoreProvider` instance
  /// wraps, so both wrappers read/write shared state. In headless tests the
  /// platform channel is unavailable: the single attempted open fails and the
  /// payload keeps the typed-[Settings] subset, byte-identical to before.
  KeyValueStore? _openedKv;
  bool _kvOpenAttempted = false;

  Future<KeyValueStore?> _kvOrOpen() async {
    if (_kv != null) return _kv;
    if (!_kvOpenAttempted) {
      _kvOpenAttempted = true;
      try {
        _openedKv = await KeyValueStore.open();
      } catch (_) {
        // No SharedPreferences backend (headless tests / early boot failure) —
        // keep the typed-[Settings] subset.
      }
    }
    return _openedKv;
  }

  /// True for a logged-in (nsec/nip46/extension) identity — `isNostrLoggedIn()`
  /// in the PWA (`loginMethod != null`). Ephemeral identities skip the durable
  /// PM archive entirely (pms.js `_pmArchiveAllowed`).
  final bool _durable;

  bool get durableIdentity => _durable;

  // ===========================================================================
  // Settings categories that sync vs stay device-local.
  // ===========================================================================

  /// The settings-modal section -> core-key map the PWA splits the synced
  /// payload into (`NYM_SETTINGS_SECTION_KEYS`, settings.js:8-25), ported
  /// 1:1. Each section is published as its own encrypted category
  /// `nymchat-settings-<section>` so a single change is a small write. Keys
  /// NOT in any list fall into `misc`.
  static const Map<String, List<String>> syncedSectionKeys = {
    'appearance': [
      'theme',
      'sound',
      'autoscroll',
      'showTimestamps',
      'timeFormat',
      'dateFormat',
      'blurOthersImages',
      'chatLayout',
      'chatViewMode',
      'columnsLayout',
      'nickStyle',
      'colorMode',
      'wallpaperType',
      'wallpaperCustomUrl',
      'textSize',
      'transparencyEnabled',
      'columnsWallpaper',
      'sidebarSectionOrder',
    ],
    'privacy': [
      'blockedUsers',
      'friends',
      'blockedKeywords',
      'blockedChannels',
      'hiddenChannels',
      'lightningAddress',
      'dmForwardSecrecyEnabled',
      'dmTTLSeconds',
      'readReceiptsEnabled',
      'readReceiptsScope',
      'typingIndicatorsEnabled',
      'typingIndicatorsScope',
      'acceptPMs',
      'acceptCalls',
      'showStatus',
      'powDifficulty',
      'encryptAtRestPreferred',
      'keypairMode',
    ],
    'messaging': [
      'groupChatPMOnlyMode',
      'translateLanguage',
      'translateFavoriteLanguages',
      'emojiPackFavorites',
      'emojiCategoryFavorites',
      'favoriteGifs',
      'recentEmojis',
      'gesturesEnabled',
      'swipeLeftAction',
      'swipeRightAction',
      'swipeThreshold',
      'swipeReactEmoji',
      'notificationsEnabled',
      'groupNotifyMentionsOnly',
      'notifyFriendsOnly',
      'syncMLSHistory',
      'seenCalls',
    ],
    'channels': [
      'pinnedChannels',
      'userJoinedChannels',
      'sortByProximity',
      'pinnedLandingChannel',
      'hideNonPinned',
      'closedPMs',
      'leftGroups',
      'closedPMTimes',
      'leftGroupTimes',
    ],
    'data': [
      'lowDataMode',
      'cachePMs',
      'tutorialSeen',
      'botPmWelcomed',
      'botPmClearedAt',
    ],
  };

  /// Settings that stay DEVICE-LOCAL and are never published. The PWA syncs
  /// everything in [syncedSectionKeys] — including `keypairMode`,
  /// `powDifficulty`, `blurOthersImages`, `hideNonPinned` and
  /// `encryptAtRestPreferred` (settings.js:101/125/126/156-164) — so the only
  /// genuinely-local surface is the identity key material itself: no key, salt
  /// or credential ever leaves the device (settings.js:160-163 comment).
  /// Exposed for tests/documentation.
  static const Set<String> deviceLocalKeys = {
    'vault', // keypair/secret material never leaves the device
  };

  /// The real (routing) category name for a section, matching the PWA's d-tag
  /// form `nymchat-settings-<section>` (settings.js:566). This is what rides
  /// INSIDE the encrypted blob as `__cat`; the cleartext D1 column is the
  /// opaque per-account hash from [d1Category].
  static String sectionCategory(String section) => 'nymchat-settings-$section';

  /// The opaque per-account D1 column for a routing [dTag]:
  /// `nymchat-<sha256hex("<pubkey>:d1:<dTag>")>` (`_d1Category` →
  /// `_syncOuterDTag('d1:' + dTag)`, settings.js:177-190). Hashing keeps
  /// per-group categories from being joined across members to reveal group
  /// membership; the real category is recovered from `__cat` in the blob.
  /// Reads stay backward-compatible: [settingsGet] recovers `__cat` from any
  /// row regardless of its column name.
  String d1Category(String dTag) =>
      'nymchat-${_sha256Hex('$_pubkey:d1:$dTag')}';

  // ===========================================================================
  // Encrypted settings sync.
  // ===========================================================================

  /// Builds the per-section settings payloads from a [Settings] snapshot,
  /// matching the PWA field names (`_buildSettingsPayload` +
  /// `_splitSettingsBySection`). Each section carries `v: 2` like the PWA.
  /// Returns `{ '<section>': { ...fields } }`.
  ///
  /// [pinnedLandingChannelJson] is the default-landing-channel choice
  /// (`nym_pinned_landing_channel`, the `{"type":"geohash","geohash":"…"}` JSON
  /// the PWA stores) read from KV by the caller. It is NOT a typed [Settings]
  /// field, so it is threaded in separately; when non-null and parseable it is
  /// emitted into the `channels` section as the same `{type,geohash}` OBJECT the
  /// PWA syncs (`pinnedLandingChannel`, settings.js:21,116).
  ///
  /// [kv] supplies the KV-backed synced prefs the PWA reads from localStorage /
  /// lazily-stored sets (`_buildSettingsPayload`, settings.js:91-165):
  /// moderation lists, pinned/hidden/joined channels, closed PMs, emoji/gif
  /// favorites, columns layout, wallpaper URL, PoW, keypair mode, … With a [kv]
  /// the landing channel also defaults to `{type:'geohash',geohash:'nymchat'}`
  /// like the PWA (settings.js:116). Null (tests / the settings-transfer path)
  /// keeps the typed-[Settings] subset, byte-identical to before.
  ///
  /// [selfPubkey] scopes the per-pubkey KV reads (`nym_image_blur_<pubkey>`,
  /// `nym_lightning_address_<pubkey>` — settings.js:1144, zaps.js:234).
  ///
  /// [extras] merges controller-owned state that is neither typed nor KV-backed
  /// on native (e.g. `leftGroups` / `leftGroupTimes` from the app state); its
  /// entries override any same-named field.
  static Map<String, Map<String, dynamic>> buildSectionPayloads(
    Settings s, {
    String? pinnedLandingChannelJson,
    Map<String, dynamic>? seenCalls,
    KeyValueStore? kv,
    String? selfPubkey,
    Map<String, dynamic>? extras,
  }) {
    // The flat synced payload (PWA `_buildSettingsPayload`). Booleans/strings/
    // ints map 1:1 to the PWA field names.
    final flat = <String, dynamic>{
      'theme': s.theme.id,
      'sound': s.sound,
      'autoscroll': s.autoscroll,
      'showTimestamps': s.showTimestamps,
      'timeFormat': s.timeFormat,
      'dateFormat': s.dateFormat,
      'chatLayout': s.chatLayout,
      'chatViewMode': s.chatViewMode,
      'columnsLayout':
          kv != null ? _kvJsonList(kv, StorageKeys.columnsLayout) : const <dynamic>[],
      'columnsWallpaper': s.columnsWallpaper,
      'nickStyle': s.nickStyle,
      'colorMode': s.colorMode.name,
      'wallpaperType': s.wallpaperType,
      'textSize': s.textSize,
      'transparencyEnabled': s.transparencyEnabled,
      'dmForwardSecrecyEnabled': s.dmForwardSecrecyEnabled,
      'dmTTLSeconds': s.dmTtlSeconds,
      'readReceiptsEnabled': s.readReceiptsScope != 'disabled',
      'readReceiptsScope': s.readReceiptsScope,
      'typingIndicatorsEnabled': s.typingIndicatorsScope != 'disabled',
      'typingIndicatorsScope': s.typingIndicatorsScope,
      'acceptPMs': s.acceptPMs,
      'acceptCalls': s.acceptCalls,
      'showStatus': _showStatusForSync(s.showStatus),
      'groupChatPMOnlyMode': s.groupChatPMOnlyMode,
      'translateLanguage': s.translateLanguage,
      'gesturesEnabled': s.gesturesEnabled,
      'swipeLeftAction': s.swipeLeftAction,
      'swipeRightAction': s.swipeRightAction,
      'swipeThreshold': s.swipeThreshold,
      'swipeReactEmoji': s.swipeReactEmoji,
      'notificationsEnabled': s.notificationsEnabled,
      'syncMLSHistory': s.syncMLSHistory,
      'sortByProximity': s.sortByProximity,
      // `nym_hide_non_pinned === 'true'` (settings.js:126) — typed on native.
      'hideNonPinned': s.hideNonPinned,
      'lowDataMode': s.lowDataMode,
      'cachePMs': s.cachePMs,
    };

    if (kv != null) {
      // KV-backed synced prefs (PWA `_buildSettingsPayload`, settings.js:91-165
      // — the PWA reads these straight from localStorage / lazy stored sets).
      // Image blur syncs as true | false | 'friends' (settings.js:101,
      // `loadImageBlurSettings` per-pubkey-then-global with a blur default).
      flat['blurOthersImages'] = _blurForSync(kv, selfPubkey);
      flat['wallpaperCustomUrl'] =
          kv.getString(StorageKeys.wallpaperCustomUrl) ?? '';
      // Sidebar order falls back to the default section ids (`
      // _getSidebarSectionOrder`, sidebar-sections.js:13-21).
      flat['sidebarSectionOrder'] = _sidebarOrderForSync(kv);
      // Moderation / social lists (settings.js:102-108) — JSON arrays in KV.
      flat['blockedUsers'] = _kvJsonList(kv, StorageKeys.blocked);
      flat['friends'] = _kvJsonList(kv, StorageKeys.friends);
      flat['blockedKeywords'] = _kvJsonList(kv, StorageKeys.blockedKeywords);
      flat['blockedChannels'] = _kvJsonList(kv, StorageKeys.blockedChannels);
      flat['hiddenChannels'] = _kvJsonList(kv, StorageKeys.hiddenChannels);
      flat['pinnedChannels'] = _kvJsonList(kv, StorageKeys.pinnedChannels);
      flat['userJoinedChannels'] =
          _kvJsonList(kv, StorageKeys.userJoinedChannels);
      // Closed-PM / left-group read state (settings.js:146-149; the PWA's
      // lazyStoredSet/Map keys, app.js:751-754).
      flat['closedPMs'] = _kvJsonList(kv, StorageKeys.closedPms);
      flat['leftGroups'] = _kvJsonList(kv, 'nym_left_groups');
      flat['closedPMTimes'] = _kvJsonMap(kv, StorageKeys.closedPmTimes);
      flat['leftGroupTimes'] = _kvJsonMap(kv, StorageKeys.leftGroupTimes);
      // Lightning address is cached per-pubkey (`nym_lightning_address_<pk>`,
      // zaps.js:234); the PWA syncs `this.lightningAddress` (null when unset).
      flat['lightningAddress'] = selfPubkey == null
          ? null
          : kv.getString(StorageKeys.lightningAddressFor(selfPubkey));
      flat['powDifficulty'] =
          kv.getInt(StorageKeys.powDifficulty, defaultValue: 0);
      flat['keypairMode'] =
          kv.getString(StorageKeys.keypairMode) ?? 'persistent';
      // Non-sensitive "I protect my identity key at rest" hint — no key
      // material ever syncs (settings.js:160-164).
      flat['encryptAtRestPreferred'] = kv.getBool(StorageKeys.encryptAtRestPref);
      // Translate / emoji / gif favorites (settings.js:132-136).
      flat['translateFavoriteLanguages'] =
          _kvJsonList(kv, StorageKeys.translateFavorites);
      flat['emojiPackFavorites'] =
          _kvJsonList(kv, StorageKeys.emojiPackFavorites);
      flat['emojiCategoryFavorites'] =
          _kvJsonList(kv, StorageKeys.emojiCategoryFavorites);
      final gifs = _favoriteGifsForSync(kv);
      if (gifs.isNotEmpty) {
        // Conditional spread like the PWA — the field is absent when empty.
        flat['favoriteGifs'] = gifs;
      }
      flat['recentEmojis'] =
          _kvJsonList(kv, StorageKeys.recentEmojis).take(24).toList();
      flat['groupNotifyMentionsOnly'] =
          kv.getString(StorageKeys.groupNotifyMentionsOnly) == 'true';
      flat['notifyFriendsOnly'] =
          kv.getString(StorageKeys.notifyFriendsOnly) == 'true';
      // Device-spanning onboarding flags (settings.js:156-158).
      flat['tutorialSeen'] = kv.getString(StorageKeys.tutorialSeen) == 'true';
      flat['botPmWelcomed'] =
          kv.getString(StorageKeys.botpmWelcomed) == 'true';
      flat['botPmClearedAt'] =
          kv.getInt(StorageKeys.botpmClearedAt, defaultValue: 0);
    }

    // Default landing channel: not a typed [Settings] field (KV-only). The
    // threaded JSON takes precedence; with a [kv] it falls back to the stored
    // value and then the PWA default (`this.pinnedLandingChannel ||
    // {type:'geohash',geohash:'nymchat'}`, settings.js:116). Without a [kv] a
    // null/blank/invalid value omits it, keeping legacy callers byte-identical.
    final landing = _parsePinnedLandingChannel(pinnedLandingChannelJson) ??
        (kv == null
            ? null
            : _parsePinnedLandingChannel(
                    kv.getString(StorageKeys.pinnedLandingChannel)) ??
                {'type': 'geohash', 'geohash': 'nymchat'});
    if (landing != null) {
      flat['pinnedLandingChannel'] = landing;
    }

    // Seen-call map: not a typed [Settings] field (owned by CallService),
    // threaded in by the caller. Emit it into the `messaging` section as the
    // same `{callId: {t,s}}` object the PWA syncs (`seenCalls`, settings.js:152)
    // so another device can merge it. Included when the caller opts in (passes a
    // map, even empty — matching the PWA, which always carries the field);
    // existing callers pass null and stay byte-identical.
    if (seenCalls != null) {
      flat['seenCalls'] = seenCalls;
    }

    // Controller-owned state (e.g. leftGroups/leftGroupTimes live in the app
    // state on native, not KV) overrides the defaults above.
    if (extras != null) {
      extras.forEach((k, v) => flat[k] = v);
    }

    final lookup = <String, String>{};
    syncedSectionKeys.forEach((section, keys) {
      for (final k in keys) {
        lookup[k] = section;
      }
    });

    final out = <String, Map<String, dynamic>>{};
    flat.forEach((key, value) {
      final section = lookup[key] ?? 'misc';
      (out[section] ??= <String, dynamic>{'v': 2})[key] = value;
    });
    return out;
  }

  /// `showStatus` is normalized to `true | false | 'friends'` for the wire
  /// (settings.js:154).
  static dynamic _showStatusForSync(String showStatus) {
    if (showStatus == 'false') return false;
    if (showStatus == 'friends') return 'friends';
    return true;
  }

  /// Decodes a KV JSON array (the PWA's JSON-array localStorage values).
  /// Anything absent/blank/non-array resolves to an empty list.
  static List<dynamic> _kvJsonList(KeyValueStore kv, String key) {
    final raw = kv.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {
      // Corrupt JSON — treat as empty.
    }
    return const [];
  }

  /// Decodes a KV JSON object (`nym_closed_pm_times` and friends). Absent /
  /// blank / non-object resolves to an empty map.
  static Map<String, dynamic> _kvJsonMap(KeyValueStore kv, String key) {
    final raw = kv.getString(key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Corrupt JSON — treat as empty.
    }
    return <String, dynamic>{};
  }

  /// The image-blur wire value `true | false | 'friends'`
  /// (`this.blurOthersImages`, settings.js:101): per-pubkey key first, then
  /// the global key, defaulting to blur=true (`loadImageBlurSettings`,
  /// settings.js:1139-1156).
  static dynamic _blurForSync(KeyValueStore kv, String? selfPubkey) {
    String? v;
    if (selfPubkey != null && selfPubkey.isNotEmpty) {
      v = kv.getString(StorageKeys.imageBlurFor(selfPubkey));
    }
    v ??= kv.getString(StorageKeys.imageBlur);
    if (v == null) return true; // default to blur
    if (v == 'friends') return 'friends';
    return v == 'true';
  }

  /// The sidebar section order for the wire (`_getSidebarSectionOrder`,
  /// sidebar-sections.js:13-21): the stored JSON array when present, else the
  /// default `['channels','pms','nyms']` (`_sidebarSectionIds`).
  static List<dynamic> _sidebarOrderForSync(KeyValueStore kv) {
    final stored = _kvJsonList(kv, StorageKeys.sidebarSectionOrder);
    if (stored.isNotEmpty) return stored;
    return const ['channels', 'pms', 'nyms'];
  }

  /// Favorite GIFs for the wire (`_getFavoriteGifs`, ui-context.js:2088-2094 +
  /// settings.js:135): entries normalized to `{url, title}`, capped at 100.
  static List<Map<String, dynamic>> _favoriteGifsForSync(KeyValueStore kv) {
    final out = <Map<String, dynamic>>[];
    for (final g in _kvJsonList(kv, StorageKeys.favoriteGifs)) {
      if (g is! Map || g['url'] is! String) continue;
      out.add({
        'url': g['url'],
        'title': g['title'] is String ? g['title'] : '',
      });
      if (out.length >= 100) break;
    }
    return out;
  }

  /// Parses the persisted landing-channel JSON
  /// (`{"type":"geohash","geohash":"…"}`) into the normalized `{type,geohash}`
  /// Map the PWA syncs (`pinnedLandingChannel`, settings.js:116). Returns null
  /// when [raw] is null/blank, isn't a JSON object, or lacks a non-empty
  /// `geohash` string (so an absent/corrupt value is simply omitted from the
  /// payload). Mirrors `LandingChannel.tryParse` in settings_helpers.dart: a
  /// missing `type` defaults to `'geohash'`.
  static Map<String, dynamic>? _parsePinnedLandingChannel(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final m = jsonDecode(trimmed);
      if (m is Map && m['geohash'] is String && (m['geohash'] as String).isNotEmpty) {
        final type = m['type'] is String ? m['type'] as String : 'geohash';
        return {'type': type, 'geohash': m['geohash'] as String};
      }
    } catch (_) {
      // Corrupt JSON — omit rather than poison the channels section.
    }
    return null;
  }

  /// Publishes the synced settings sections to D1. For each section it encrypts
  /// the blob (NIP-44 to self) with the real category embedded as `__cat`,
  /// computes the `contentHash` (sha256 of `pubkey|blob-plaintext`) the worker
  /// uses to no-op unchanged writes, and POSTs `settings-set`.
  ///
  /// Returns the set of section names that were sent (changed since last call).
  /// All failures are swallowed; an unchanged section (same content hash) is
  /// skipped without a network call. Mirrors `_saveSettingsBlobToD1`.
  ///
  /// [pinnedLandingChannelJson] is the KV-stored default-landing-channel choice
  /// (not a typed [Settings] field); the caller reads it via
  /// `SettingsController.pinnedLandingChannelJson` and passes it so it rides the
  /// `channels` section like the PWA (settings.js:21,116). When omitted it is
  /// read from the injected KV store (falling back to the PWA default).
  /// [extras] threads controller-owned state (`leftGroups`/`leftGroupTimes`)
  /// into the payload — see [buildSectionPayloads].
  Future<Set<String>> settingsSet(
    Settings settings, {
    String? pinnedLandingChannelJson,
    Map<String, dynamic>? seenCalls,
    Map<String, dynamic>? extras,
  }) async {
    final sent = <String>{};
    final sections = buildSectionPayloads(
      settings,
      pinnedLandingChannelJson: pinnedLandingChannelJson,
      seenCalls: seenCalls,
      kv: await _kvOrOpen(),
      selfPubkey: _pubkey,
      extras: extras,
    );
    for (final entry in sections.entries) {
      // The real category (`nymchat-settings-<section>`) rides inside the
      // encrypted blob as `__cat`; the D1 column is its opaque per-account
      // hash (`_d1Category`, settings.js:189/725). Only the channels section
      // carries a trim fn (`_trimChannelsReadState`, settings.js:567).
      final ok = await _publishCategoryWrap(
        Map<String, dynamic>.of(entry.value),
        sectionCategory(entry.key),
        trim: entry.key == 'channels' ? _trimChannelsReadState : null,
      );
      if (ok) sent.add(entry.key);
    }
    return sent;
  }

  /// Relay-side NIP-59 `nym-sync` publisher (`_publishWrappedNostrEvent`,
  /// settings.js:598-663), injected by the controller and wired to
  /// `NostrService.publishNymSyncWrap`. Called with the plaintext payload
  /// (WITHOUT `__cat` — the wrap rumor carries the real d-tag in its `d` tag
  /// instead) after the D1 write, so other devices get a live push even when
  /// the D1 worker is unreachable. Null (unwired) keeps the D1-only behavior.
  Future<void> Function(Map<String, dynamic> payload, String dTag)?
      _syncWrapPublisher;

  /// Registers the relay `nym-sync` gift-wrap publisher (see
  /// [_syncWrapPublisher]).
  void setSyncWrapPublisher(
    Future<void> Function(Map<String, dynamic> payload, String dTag) publisher,
  ) {
    _syncWrapPublisher = publisher;
  }

  /// Last-published payload JSON per d-tag, so an unchanged category is not
  /// re-written/re-wrapped (`_publishedSectionJson`, settings.js:385-388).
  final Map<String, String> _publishedSectionJson = {};

  /// The payload is encrypted twice (seal kind 13 → gift wrap kind 1059) and
  /// base64 expands it ~1.9x; bound the inner rumor so the wrapped event stays
  /// under common ~64KiB relay caps (`_publishCategoryWrap`, settings.js:352-358).
  static const int _rumorOverhead = 256;
  static const int _maxWrappedBytes = 60000;
  static final int _maxRumorBytes = (_maxWrappedBytes / 1.95).floor();

  /// Approximate rumor byte size: UTF-8 length of the double-JSON-stringified
  /// payload plus the fixed rumor overhead (settings.js:359-363).
  static int _rumorByteSize(Map<String, dynamic> payload) =>
      utf8.encode(jsonEncode(jsonEncode(payload))).length + _rumorOverhead;

  /// Drops the oldest entries from the channels section's auto-growing
  /// read-state maps so the payload fits under the NIP-44 limit instead of
  /// being skipped (`_trimChannelsReadState`, settings.js:574-588). Only map
  /// shapes are trimmed (the array forms of closedPMs/leftGroups are not).
  static bool _trimChannelsReadState(Map<String, dynamic> p) {
    for (final key in const [
      'closedPMTimes',
      'leftGroupTimes',
      'closedPMs',
      'leftGroups',
    ]) {
      final m = p[key];
      if (m is! Map) continue;
      if (m.length <= 30) continue;
      final entries = m.entries.toList()
        ..sort((a, b) {
          final na = a.value is num ? a.value as num : 0;
          final nb = b.value is num ? b.value as num : 0;
          return na.compareTo(nb);
        });
      var drop = (entries.length * 0.25).floor();
      if (drop < 1) drop = 1;
      for (var i = 0; i < drop; i++) {
        m.remove(entries[i].key);
      }
      return true;
    }
    return false;
  }

  /// Drops the oldest 25% of seen-notification keys (`trimOldestSeen`,
  /// settings.js:549-556).
  static bool _trimOldestSeen(Map<String, dynamic> p) {
    final o = p['seenNotifications'];
    if (o is! Map) return false;
    if (o.length <= 1) return false;
    final keys = o.keys.toList()
      ..sort((a, b) {
        final na = o[a] is num ? o[a] as num : 0;
        final nb = o[b] is num ? o[b] as num : 0;
        return na.compareTo(nb);
      });
    var drop = (keys.length * 0.25).ceil();
    if (drop < 1) drop = 1;
    for (var i = 0; i < drop; i++) {
      o.remove(keys[i]);
    }
    return true;
  }

  /// Publishes one data category as a D1 blob + a NIP-59 `nym-sync` relay
  /// wrap, mirroring `_publishCategoryWrap` (settings.js:351-391): trims via
  /// [trim] until the rumor fits the NIP-44 plaintext budget (≤500 rounds),
  /// skips the publish entirely when still oversized, skips a payload that is
  /// byte-identical to the last one sent for this [dTag], then writes the D1
  /// blob and hands the plaintext payload to the injected wrap publisher.
  /// Returns whether the D1 category was actually sent.
  Future<bool> _publishCategoryWrap(
    Map<String, dynamic> payload,
    String dTag, {
    bool Function(Map<String, dynamic> p)? trim,
  }) async {
    if (trim != null) {
      var guard = 0;
      while (_rumorByteSize(payload) > _maxRumorBytes && guard++ < 500) {
        if (!trim(payload)) break;
      }
    }
    if (_rumorByteSize(payload) > _maxRumorBytes) return false;

    final json = jsonEncode(payload);
    if (_publishedSectionJson[dTag] == json) return false; // unchanged
    _publishedSectionJson[dTag] = json;

    final ok = await _setSettingsCategory(
      d1Category(dTag),
      jsonEncode(_withCat(payload, dTag)),
    );
    // Relay wrap is best-effort and independent of the D1 result (the PWA
    // fire-and-forgets `_saveSettingsBlobToD1` before wrapping).
    final wrapPublisher = _syncWrapPublisher;
    if (wrapPublisher != null) {
      try {
        await wrapPublisher(payload, dTag);
      } catch (_) {
        // Best-effort relay push.
      }
    }
    return ok;
  }

  /// Publishes the cross-device notification read-state wrap — the PWA's
  /// `nymchat-notifications` category (settings.js:559). N26 scopes this to the
  /// seen-keys map (`seenNotifications`, the read-state); the bell history blob
  /// itself stays device-local (its cross-device sync is out of N26's scope).
  /// No-op (and no network call) when [seenNotifications] is empty or unchanged
  /// since the last publish (content-hash dedup in [_setSettingsCategory]).
  /// Returns whether the category was actually sent.
  Future<bool> notificationsWrapSet(
      Map<String, dynamic> seenNotifications) async {
    if (seenNotifications.isEmpty) return false;
    const dTag = 'nymchat-notifications';
    final payload = <String, dynamic>{
      'v': 2,
      'seenNotifications': Map<String, dynamic>.of(seenNotifications),
    };
    // Same hashed-column scheme + wrap path as the settings sections
    // (settings.js:559-560 routes this category through `_publishCategoryWrap`
    // with the oldest-seen trim, `trimOldestSeen`).
    return _publishCategoryWrap(payload, dTag, trim: _trimOldestSeen);
  }

  /// Publishes the cross-device read-state category — the PWA's
  /// `nymchat-readstate` blob (`_syncReadStateToD1`, settings.js:745-776). Carries
  /// the full `{channelLastRead}` map (per-channel / PM / group read watermarks)
  /// so another device restores its unread badges. Unlike the settings sections
  /// this is a D1-only write (no relay `nym-sync` wrap — the PWA routes it through
  /// `_saveSettingsBlobToD1`, not `_publishCategoryWrap`), deduped by content hash
  /// in [_setSettingsCategory]. Entries with a non-positive ts are dropped and the
  /// most-recently-read 2000 are kept (settings.js:757-762). No-op (no network)
  /// when [channelLastRead] is empty or unchanged since the last publish. Returns
  /// whether the category was actually sent.
  Future<bool> readStateSet(Map<String, int> channelLastRead) async {
    if (channelLastRead.isEmpty) return false;
    final entries = <MapEntry<String, int>>[
      for (final e in channelLastRead.entries)
        if (e.value > 0) MapEntry(e.key, e.value),
    ];
    if (entries.isEmpty) return false;
    // Keep the most-recently-read conversations (settings.js:758-762).
    entries.sort((a, b) => b.value.compareTo(a.value));
    const maxEntries = 2000;
    final capped =
        entries.length > maxEntries ? entries.sublist(0, maxEntries) : entries;
    final map = <String, dynamic>{for (final e in capped) e.key: e.value};
    const dTag = 'nymchat-readstate';
    // The PWA's payload is a bare `{channelLastRead}` (settings.js:767); the real
    // category rides inside the blob as `__cat` so the D1 column stays opaque.
    final payload = <String, dynamic>{'channelLastRead': map};
    return _setSettingsCategory(
      d1Category(dTag),
      jsonEncode(_withCat(payload, dTag)),
    );
  }

  // ===========================================================================
  // Per-group cross-device sync categories (settings.js `_publishEncryptedSettings`
  // group branches, 435-529). Each rides the SAME hashed-column settings-set path
  // as the settings sections, so a fresh device restores group membership,
  // decryption keys, and backlog. The apply side is [settingsGet].
  // ===========================================================================

  /// The d-tag for a per-group sync category — `<prefix>-<lowercased gid>`
  /// (`_groupSyncDTag`, settings.js:169). Used for `nymchat-keys` and
  /// `nymchat-history`; `nymchat-groups` is a single account-wide category.
  static String _groupSyncDTag(String prefix, String groupId) =>
      '$prefix-${groupId.toLowerCase()}';

  /// `YYYYMM` bucket id for a unix-seconds timestamp (`_historyBucketId`,
  /// settings.js:511), used to time-bucket group history so each wrap holds at
  /// most one month of messages.
  static String _historyBucketId(int tsSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        (tsSeconds < 0 ? 0 : tsSeconds) * 1000,
        isUtc: true);
    final mm = d.month.toString().padLeft(2, '0');
    return '${d.year}$mm';
  }

  /// Publishes the three per-group cross-device categories, mirroring the group
  /// branches of `_publishEncryptedSettings` (settings.js:435-529):
  ///
  ///  * **`nymchat-keys-<gid>`** — one wrap per group carrying `{groupEphemeralKeys:
  ///    {gid: entry}}`; stale members (not in [groupConversations]'s member list)
  ///    are dropped, and left groups are skipped entirely.
  ///  * **`nymchat-groups`** — a single `{groupConversations: {...}}` wrap.
  ///  * **`nymchat-history-<gid>-<YYYYMM>-<shard>`** — the group backlog bucketed
  ///    by month and packed into byte-bounded shards.
  ///
  /// [groupConversations] is `gid → serialized group` (the caller builds it from
  /// the group store, matching `_buildGroupConversationsSync`). [ephemeralKeysByGroup]
  /// is `gid → serialized ephemeral-key entry` (from `GroupManager.ephemeralKeysForSync`).
  /// [historyByConvKey] is `group-<gid> → [message maps]` (the stripped `{id,
  /// pubkey, content, created_at, isOwn, groupId, nymMessageId}` form). Every
  /// category dedups against the last publish by content hash, so an unchanged
  /// group produces no network write. Best-effort; failures per category are
  /// swallowed like the PWA's per-branch `try/catch`.
  Future<void> groupSyncSet({
    required Map<String, Map<String, dynamic>> groupConversations,
    required Map<String, Map<String, dynamic>> ephemeralKeysByGroup,
    required Map<String, List<Map<String, dynamic>>> historyByConvKey,
    Set<String> leftGroups = const {},
  }) async {
    // Group ephemeral keys → nymchat-keys-<gid> (one wrap per group).
    for (final e in ephemeralKeysByGroup.entries) {
      final gid = e.key;
      if (leftGroups.contains(gid)) continue;
      try {
        final entry = _pruneEphemeralEntry(
          Map<String, dynamic>.of(e.value),
          groupConversations[gid],
        );
        await _publishCategoryWrap(
          {
            'groupEphemeralKeys': {gid: entry},
          },
          _groupSyncDTag('nymchat-keys', gid),
          trim: _trimEphemeralKeys,
        );
      } catch (_) {
        // Best-effort per group (settings.js:461 `catch (_) {}`).
      }
    }

    // Group conversation metadata → nymchat-groups.
    if (groupConversations.isNotEmpty) {
      try {
        await _publishCategoryWrap(
          {'groupConversations': groupConversations},
          'nymchat-groups',
          trim: _trimGroupModLogs,
        );
      } catch (_) {
        // Best-effort.
      }
    }

    // Group message history → nymchat-history-<gid>-<YYYYMM>-<shard>.
    const shardBudget = 30000; // ~30 KB of message JSON per shard (settings.js:497).
    for (final e in historyByConvKey.entries) {
      final convKey = e.key;
      final msgs = e.value;
      if (msgs.isEmpty) continue;
      try {
        final gid =
            convKey.startsWith('group-') ? convKey.substring(6) : convKey;
        final base = _groupSyncDTag('nymchat-history', gid);
        // Partition into month buckets.
        final buckets = <String, List<Map<String, dynamic>>>{};
        for (final m in msgs) {
          final b = _historyBucketId((m['created_at'] as num?)?.toInt() ?? 0);
          (buckets[b] ??= <Map<String, dynamic>>[]).add(m);
        }
        for (final be in buckets.entries) {
          final bucket = be.key;
          final list = be.value
            ..sort((a, b) {
              final ca = (a['created_at'] as num?)?.toInt() ?? 0;
              final cb = (b['created_at'] as num?)?.toInt() ?? 0;
              if (ca != cb) return ca - cb;
              final ia = a['id']?.toString() ?? '';
              final ib = b['id']?.toString() ?? '';
              return ia.compareTo(ib);
            });
          var shard = 0;
          var shardMsgs = <Map<String, dynamic>>[];
          var shardBytes = 0;
          Future<void> flush() async {
            if (shardMsgs.isEmpty) return;
            await _publishCategoryWrap(
              {
                'groupMessageHistory': {convKey: shardMsgs},
              },
              '$base-$bucket-$shard',
              trim: _trimOldestHistory,
            );
            shard++;
            shardMsgs = <Map<String, dynamic>>[];
            shardBytes = 0;
          }

          for (final m in list) {
            final sz = jsonEncode(m).length + 4;
            if (shardBytes + sz > shardBudget && shardMsgs.isNotEmpty) {
              await flush();
            }
            shardMsgs.add(m);
            shardBytes += sz;
          }
          await flush();
        }
      } catch (_) {
        // Best-effort per conversation.
      }
    }
  }

  /// Drops ephemeral-key member entries not in the group's current member list,
  /// keeping the payload bounded (settings.js:441-448). Returns the same [entry].
  static Map<String, dynamic> _pruneEphemeralEntry(
    Map<String, dynamic> entry,
    Map<String, dynamic>? group,
  ) {
    final memberList = group?['members'];
    final members = entry['members'];
    if (memberList is! List || members is! Map) return entry;
    final memberSet = memberList.map((m) => m.toString()).toSet();
    final ts = entry['memberKeyTs'];
    for (final realPk in members.keys.toList()) {
      if (!memberSet.contains(realPk.toString())) {
        members.remove(realPk);
        if (ts is Map) ts.remove(realPk);
      }
    }
    return entry;
  }

  /// Trims the oldest quarter of the (only) group's prev keys, then drops
  /// `memberKeyTs`, when the keys payload is oversized (`trimEphemeralPrevKeys` +
  /// `trimMemberKeyTs`, settings.js:427-434).
  static bool _trimEphemeralKeys(Map<String, dynamic> p) {
    final map = p['groupEphemeralKeys'];
    if (map is! Map || map.isEmpty) return false;
    final entry = map.values.first;
    if (entry is! Map) return false;
    final self = entry['self'];
    if (self is Map) {
      final prev = self['prev'];
      if (prev is List && prev.isNotEmpty) {
        final dropCount = (prev.length * 0.25).ceil().clamp(1, prev.length);
        prev.removeRange(prev.length - dropCount, prev.length);
        if (prev.isEmpty) self.remove('prev');
        return true;
      }
    }
    if (entry['memberKeyTs'] is Map) {
      entry.remove('memberKeyTs');
      return true;
    }
    return false;
  }

  /// Halves every group's modLog when the conversations payload is oversized
  /// (`trimGroupModLogs`, settings.js:479-488).
  static bool _trimGroupModLogs(Map<String, dynamic> p) {
    final groups = p['groupConversations'];
    if (groups is! Map) return false;
    var trimmed = false;
    for (final g in groups.values) {
      if (g is! Map) continue;
      final modLog = g['modLog'];
      if (modLog is List && modLog.isNotEmpty) {
        final keep = modLog.length - (modLog.length / 2).ceil();
        g['modLog'] = modLog.sublist(modLog.length - keep);
        trimmed = true;
      }
    }
    return trimmed;
  }

  /// Last-resort guard dropping the oldest ~10% of a shard's messages when a
  /// single message is itself enormous (`trimOldestHistory`, settings.js:516-522).
  static bool _trimOldestHistory(Map<String, dynamic> p) {
    final hist = p['groupMessageHistory'];
    if (hist is! Map || hist.isEmpty) return false;
    final k = hist.keys.first;
    final arr = hist[k];
    if (arr is! List || arr.length <= 1) return false;
    final drop = (arr.length * 0.1).ceil().clamp(1, arr.length);
    final next = arr.sublist(drop);
    if (next.isEmpty) {
      hist.remove(k);
    } else {
      hist[k] = next;
    }
    return true;
  }

  /// Embeds the real category into the (to-be-encrypted) blob as `__cat`
  /// (settings.js:720) so the cleartext D1 column can stay opaque.
  Map<String, dynamic> _withCat(Map<String, dynamic> payload, String category) {
    return {...payload, '__cat': category};
  }

  /// In-memory content-hash cache so an unchanged section skips the write
  /// (the PWA persists this in localStorage as `nym_settings_hash_*`).
  final Map<String, String> _lastSettingsHash = {};

  Future<bool> _setSettingsCategory(String category, String plaintext) async {
    try {
      final hash = _sha256Hex('$_pubkey|$plaintext');
      final hashKey = '${_pubkey}_$category';
      if (_lastSettingsHash[hashKey] == hash) return false; // unchanged

      final blob = await _encryptToSelf(plaintext);
      if (blob == null) return false;

      final body = <String, dynamic>{
        'action': 'settings-set',
        'pubkey': _pubkey,
        'category': category,
        'blob': blob,
        'contentHash': hash,
        'auth': await _auth('settings-set'),
      };
      await _api.storageAction(body);
      _lastSettingsHash[hashKey] = hash;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Loads encrypted settings categories from D1 and decodes them into a merged
  /// payload + the newest `updatedAt` (ms) across the applied core sections.
  ///
  /// Mirrors `settingsLoadFromD1`: each category's blob is decrypted, the real
  /// category recovered from `__cat`, the section blobs applied oldest-to-newest
  /// (newest values win). Returns null on any failure / no record so the caller
  /// keeps the device-local settings. The caller is responsible for honoring
  /// `nym_last_settings_sync_ts` (only apply when [SettingsLoadResult.newestTs]
  /// exceeds the stored sync ts).
  Future<SettingsLoadResult?> settingsGet() async {
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'settings-get',
        'pubkey': _pubkey,
        'auth': await _auth('settings-get'),
      });
    } catch (_) {
      return null;
    }
    final cats = data['categories'];
    if (cats is! Map) return null;

    final decoded = <_DecodedCategory>[];
    for (final e in cats.entries) {
      final entry = e.value;
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      final updatedAt = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      try {
        final plain = await _decryptFromSelf(blob);
        if (plain == null) continue;
        final payload = jsonDecode(plain);
        if (payload is! Map<String, dynamic>) continue;
        final realCat =
            payload['__cat'] is String ? payload['__cat'] as String : e.key.toString();
        payload.remove('__cat');
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable/corrupt category.
      }
    }
    if (decoded.isEmpty) return null;

    // N26: pull the cross-device notification read-state wrap (a separate
    // category from the settings sections) so the caller can merge its seen-keys.
    Map<String, dynamic>? notificationsPayload;
    // The `nymchat-readstate` category (per-channel/PM/group read watermarks)
    // rides alongside the settings sections but is non-core; the PWA applies it
    // additively (settings.js:815-819). Surface it so the caller can merge its
    // `channelLastRead` map regardless of the core-section ts gate.
    Map<String, dynamic>? readStatePayload;
    // The per-group cross-device categories (settings.js:435-529) — decoded here
    // and merged so the caller restores group membership, decryption keys, and
    // backlog on a fresh device. Non-core / additive, applied regardless of the
    // core-section ts gate (the PWA routes them through `applyNostrSettingsAdditive`).
    Map<String, dynamic>? groupConversations;
    final groupEphemeralKeys = <String, dynamic>{};
    final groupMessageHistory = <String, List<dynamic>>{};
    for (final d in decoded) {
      final c = d.category;
      if (c == 'nymchat-notifications') notificationsPayload = d.payload;
      if (c == 'nymchat-readstate') readStatePayload = d.payload;
      if (c == 'nymchat-groups') {
        final gc = d.payload['groupConversations'];
        if (gc is Map) {
          groupConversations = {
            ...?groupConversations,
            ...gc.cast<String, dynamic>(),
          };
        }
      } else if (c.startsWith('nymchat-keys-')) {
        final ek = d.payload['groupEphemeralKeys'];
        if (ek is Map) {
          ek.forEach((gid, entry) => groupEphemeralKeys[gid.toString()] = entry);
        }
      } else if (c.startsWith('nymchat-history-')) {
        final hist = d.payload['groupMessageHistory'];
        if (hist is Map) {
          hist.forEach((convKey, msgs) {
            if (msgs is List) {
              (groupMessageHistory[convKey.toString()] ??= <dynamic>[])
                  .addAll(msgs);
            }
          });
        }
      }
    }

    bool isCore(String c) =>
        c == 'nymchat-settings' || c.startsWith('nymchat-settings-');

    // Section blobs are authoritative: apply oldest-to-newest so the most
    // recently saved value wins; fall back to the legacy monolithic blob only
    // when no section blobs exist (settings.js:824).
    final core = decoded.where((d) => isCore(d.category)).toList();
    final sections = core.where((d) => d.category != 'nymchat-settings').toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final toApply = sections.isNotEmpty
        ? sections
        : core.where((d) => d.category == 'nymchat-settings').toList();
    final hasGroupData = groupConversations != null ||
        groupEphemeralKeys.isNotEmpty ||
        groupMessageHistory.isNotEmpty;
    if (toApply.isEmpty) {
      // No settings sections to apply — but a notifications wrap, a readstate
      // category, or per-group data alone is still worth returning so the caller
      // can merge the seen-keys (N26) / read watermarks / group restore.
      return (notificationsPayload == null &&
              readStatePayload == null &&
              !hasGroupData)
          ? null
          : SettingsLoadResult(
              payload: const {},
              newestTs: 0,
              notificationsPayload: notificationsPayload,
              readStatePayload: readStatePayload,
              groupConversations: groupConversations,
              groupEphemeralKeys: groupEphemeralKeys,
              groupMessageHistory: groupMessageHistory,
            );
    }

    final merged = <String, dynamic>{};
    var newestTs = 0;
    for (final d in toApply) {
      merged.addAll(d.payload);
      if (d.updatedAt > newestTs) newestTs = d.updatedAt;
    }
    return SettingsLoadResult(
      payload: merged,
      newestTs: newestTs,
      notificationsPayload: notificationsPayload,
      readStatePayload: readStatePayload,
      groupConversations: groupConversations,
      groupEphemeralKeys: groupEphemeralKeys,
      groupMessageHistory: groupMessageHistory,
    );
  }

  /// Fetches inbound settings-transfer offers: the per-section encrypted
  /// settings categories in D1 whose `updatedAt` is newer than [sinceMs] (the
  /// stored `nym_last_settings_sync_ts`, in ms). These are settings another of
  /// the user's devices published that this device hasn't applied yet — the
  /// inbound side of the cross-device settings sync (settings.js
  /// `settingsLoadFromD1`, surfaced here as discrete accept/decline offers rather
  /// than auto-applied).
  ///
  /// Each offer carries the real section name, the decrypted payload (PWA field
  /// names, `__cat` stripped) and its `updatedAt` (ms), newest-first. Returns an
  /// empty list on any failure / when nothing is newer than [sinceMs]. The
  /// legacy monolithic `nymchat-settings` blob is included as a single offer
  /// only when no section blobs exist (mirroring `settingsGet`'s fallback).
  Future<List<SettingsTransferOffer>> settingsTransfersSince(int sinceMs) async {
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'settings-get',
        'pubkey': _pubkey,
        'auth': await _auth('settings-get'),
      });
    } catch (_) {
      return const [];
    }
    final cats = data['categories'];
    if (cats is! Map) return const [];

    final decoded = <_DecodedCategory>[];
    for (final e in cats.entries) {
      final entry = e.value;
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      final updatedAt = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      try {
        final plain = await _decryptFromSelf(blob);
        if (plain == null) continue;
        final payload = jsonDecode(plain);
        if (payload is! Map<String, dynamic>) continue;
        final realCat = payload['__cat'] is String
            ? payload['__cat'] as String
            : e.key.toString();
        payload.remove('__cat');
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable/corrupt category.
      }
    }
    if (decoded.isEmpty) return const [];

    bool isCore(String c) =>
        c == 'nymchat-settings' || c.startsWith('nymchat-settings-');
    final core = decoded.where((d) => isCore(d.category)).toList();
    final sections =
        core.where((d) => d.category != 'nymchat-settings').toList();
    final source = sections.isNotEmpty
        ? sections
        : core.where((d) => d.category == 'nymchat-settings').toList();

    final offers = <SettingsTransferOffer>[];
    for (final d in source) {
      if (d.updatedAt <= sinceMs) continue;
      final section = d.category.startsWith('nymchat-settings-')
          ? d.category.substring('nymchat-settings-'.length)
          : d.category;
      offers.add(SettingsTransferOffer(
        id: d.category,
        section: section,
        payload: d.payload,
        updatedAt: d.updatedAt,
      ));
    }
    // The non-core `nymchat-readstate` category (per-conversation read
    // watermarks) is applied additively by the PWA (settings.js:815-819); surface
    // it here too so the modal-open refresh path applies its `channelLastRead`
    // when newer than the last sync — the read side of cross-device unread state.
    for (final d in decoded) {
      if (d.category != 'nymchat-readstate') continue;
      if (d.updatedAt <= sinceMs) continue;
      offers.add(SettingsTransferOffer(
        id: d.category,
        section: d.category,
        payload: d.payload,
        updatedAt: d.updatedAt,
      ));
    }
    offers.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return offers;
  }

  // ===========================================================================
  // D1-first profile mirror.
  // ===========================================================================

  /// Per-pubkey TTL cache of profiles already served from D1 so repeat lookups
  /// skip the round-trip (`_d1ProfileCache`, nostr-core.js:210). Value is the ms
  /// timestamp it was cached at.
  final Map<String, int> _profileCacheAt = {};
  static const int _profileCacheTtlMs = 5 * 60 * 1000;

  /// Batch-reads kind-0 profiles from D1 for [pubkeys] (public, unauthenticated
  /// `profile-get`, up to 100 per request). Returns the signed kind-0 events
  /// keyed by pubkey for the ones D1 had — the caller routes each through the
  /// normal kind-0 ingest path so the `kind0Ts` dedup keeps relay updates
  /// authoritative, then falls back to a relay REQ for the missing pubkeys
  /// (`_flushProfileBatch`, nostr-core.js:1784).
  ///
  /// Honors the in-memory TTL cache: already-fresh pubkeys are reported as
  /// "found" (so the caller won't re-REQ them) but are not re-fetched. Failures
  /// resolve to an empty map (caller falls back to relays).
  Future<Map<String, Map<String, dynamic>>> profileGet(
    List<String> pubkeys,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final toFetch = <String>[];
    final foundFromCache = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk)) continue;
      final at = _profileCacheAt[pk];
      if (at != null && now - at < _profileCacheTtlMs) {
        foundFromCache.add(pk);
        continue;
      }
      toFetch.add(pk);
    }
    final batch = toFetch.take(100).toList();
    final out = <String, Map<String, dynamic>>{};
    // Report cache hits so the caller skips them; no event to return for those.
    for (final pk in foundFromCache) {
      out.putIfAbsent(pk, () => const {});
    }
    if (batch.isEmpty) return out;

    StorageStream stream;
    try {
      // profile-get is a PUBLIC read (no auth, storage.js:589).
      stream = await _api.storageStream({
        'action': 'profile-get',
        'pubkeys': batch,
      });
    } catch (_) {
      return out;
    }
    for (final item in stream.items) {
      // Each line is `[pubkey, rec]` where rec is `{event, updatedAt}` or null.
      if (item is! List || item.length < 2) continue;
      final pk = item[0];
      final rec = item[1];
      if (pk is! String) continue;
      if (rec is! Map) continue;
      final event = rec['event'];
      if (event is! Map) continue;
      out[pk.toLowerCase()] = Map<String, dynamic>.from(event);
      _profileCacheAt[pk.toLowerCase()] = now;
    }
    return out;
  }

  /// Marks [pubkey] as freshly cached (called after a relay/own kind-0 arrives
  /// so a D1 read isn't issued for a profile we already have).
  void markProfileCached(String pubkey) {
    _profileCacheAt[pubkey.toLowerCase()] =
        DateTime.now().millisecondsSinceEpoch;
  }

  /// Mirrors a signed own kind-0 profile event to D1 (`profile-set`) in addition
  /// to the relay publish, so other clients get a fast public read
  /// (`_saveProfileToD1`, nostr-core.js:194). [signedEvent] is the full signed
  /// kind-0 event JSON. Best-effort; failures are swallowed.
  Future<void> profileSet(Map<String, dynamic> signedEvent) async {
    try {
      await _api.storageAction({
        'action': 'profile-set',
        'pubkey': _pubkey,
        'event': signedEvent,
        'auth': await _auth('profile-set'),
      });
      final id = signedEvent['id'];
      if (id is String) markProfileCached(_pubkey);
    } catch (_) {
      // Best-effort mirror.
    }
  }

  // ===========================================================================
  // PM gift-wrap archive (durable identities only).
  // ===========================================================================

  /// Processed wrap-id set so a wrap is uploaded at most once per session
  /// (`_pmArchivedIds`, pms.js:1415). Capped like the PWA (6000 → trim to 4000).
  final Set<String> _archivedIds = {};
  final Set<String> _depositedIds = {};

  /// Uploads gift wraps addressed to us into our own D1 inbox (`pm-put`) so a
  /// new device can restore them. No-op for ephemeral identities. [wraps] are
  /// full signed kind-1059 events; only wraps p-tagged to us and not already
  /// uploaded this session are sent. Returns the count actually sent.
  Future<int> pmPut(List<Map<String, dynamic>> wraps) async {
    if (!_durable) return 0;
    final batch = <Map<String, dynamic>>[];
    for (final w in wraps) {
      final id = w['id'];
      if (id is! String || id.isEmpty) continue;
      if (!_addressedTo(w, _pubkey)) continue;
      if (_archivedIds.contains(id)) continue;
      _archivedIds.add(id);
      batch.add(w);
    }
    _trim(_archivedIds);
    if (batch.isEmpty) return 0;
    try {
      await _api.storageAction({
        'action': 'pm-put',
        'pubkey': _pubkey,
        'events': batch.take(100).toList(),
        'auth': await _auth('pm-put'),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
  }

  /// Deposits a recipient-addressed wrap into the *recipient's* inbox
  /// (`pm-deposit`) so they can restore it even if they were offline when we
  /// sent it (`_depositPMEvent`, pms.js:1449). Skips wraps addressed to
  /// ourselves. No-op for ephemeral identities. Returns the count sent.
  Future<int> pmDeposit(List<Map<String, dynamic>> wraps) async {
    if (!_durable) return 0;
    final batch = <Map<String, dynamic>>[];
    for (final w in wraps) {
      final id = w['id'];
      if (id is! String || id.isEmpty) continue;
      final recipient = _recipientOf(w);
      if (recipient == null || recipient == _pubkey) continue;
      if (_depositedIds.contains(id)) continue;
      _depositedIds.add(id);
      batch.add(w);
    }
    _trim(_depositedIds);
    if (batch.isEmpty) return 0;
    try {
      await _api.storageAction({
        'action': 'pm-deposit',
        'pubkey': _pubkey,
        'events': batch.take(100).toList(),
        'auth': await _auth('pm-deposit'),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
  }

  /// Removes archived gift wraps by id from OUR D1 inbox (`pm-delete`,
  /// storage.js:945-961; the worker deletes only rows under our own pubkey).
  /// Chunked to the server's 200-id cap, mirroring `_purgeBotPMArchive`
  /// (pms.js:1883-1891) and the NIP-09 PM branch of `_propagateDeletionToD1`
  /// (nostr-core.js:1879-1883). No-op for ephemeral identities. Returns the
  /// number of rows the worker reported removed; failures are swallowed.
  Future<int> pmDelete(List<String> ids) async {
    if (!_durable) return 0;
    final clean = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.toLowerCase();
      if (_isHex64(id) && seen.add(id)) clean.add(id);
    }
    var removed = 0;
    for (var i = 0; i < clean.length; i += 200) {
      final end = (i + 200) < clean.length ? i + 200 : clean.length;
      try {
        final res = await _api.storageAction({
          'action': 'pm-delete',
          'pubkey': _pubkey,
          'ids': clean.sublist(i, end),
          'auth': await _auth('pm-delete'),
        });
        removed += (res['removed'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // Best-effort purge.
      }
    }
    return removed;
  }

  /// Oldest restored wrap ts (`_pmD1OldestTs`) + an end-of-history flag
  /// (`_pmD1NoMore`) driving the pager (pms.js:1502).
  int? _pmOldestTs;
  bool _pmNoMore = false;

  /// Restores archived gift wraps from our D1 inbox (`pm-get`), newest first.
  /// Returns the parsed wrap events sorted oldest-to-newest, deduped against the
  /// session's processed-id set so the same wrap isn't re-applied. No-op (empty
  /// list) for ephemeral identities. Updates the pager state so
  /// [pmLoadOlderFromD1] can continue. Mirrors `_pmRestoreD1Page`.
  Future<List<Map<String, dynamic>>> pmGet({
    int since = 0,
    int before = 0,
    int limit = 200,
  }) async {
    if (!_durable) return const [];
    StorageStream stream;
    try {
      stream = await _api.storageStream({
        'action': 'pm-get',
        'pubkey': _pubkey,
        'since': since,
        if (before > 0) 'before': before,
        'limit': limit,
        'auth': await _auth('pm-get'),
      });
    } catch (_) {
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      if (_archivedIds.contains(id)) continue;
      _archivedIds.add(id);
      events.add(Map<String, dynamic>.from(item));
    }
    _trim(_archivedIds);
    // End-of-history when the worker says no more OR the page was short.
    if (!stream.hasMore || events.length < limit) _pmNoMore = true;
    events.sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
    if (events.isNotEmpty) {
      final oldest = _createdAt(events.first);
      if (oldest > 0 && (_pmOldestTs == null || oldest < _pmOldestTs!)) {
        _pmOldestTs = oldest;
      }
    }
    return events;
  }

  /// Restores the initial backlog (up to 5 pages of 200, newest first), the
  /// boot-time `pmRestoreFromD1` (pms.js:1500). Returns the combined wraps
  /// (oldest-to-newest). Resets the pager state.
  Future<List<Map<String, dynamic>>> pmRestoreFromD1() async {
    if (!_durable) return const [];
    _pmOldestTs = null;
    _pmNoMore = false;
    const maxPages = 5;
    var before = 0;
    final all = <Map<String, dynamic>>[];
    for (var page = 0; page < maxPages; page++) {
      final got = await pmGet(before: before, limit: 200);
      all.addAll(got);
      if (got.isEmpty || _pmNoMore || _pmOldestTs == null) break;
      before = _pmOldestTs!;
    }
    return all;
  }

  /// Loads the next older page when a conversation is scrolled back
  /// (`pmLoadOlderFromD1`, pms.js:1514). Returns an empty list when there's no
  /// more history.
  Future<List<Map<String, dynamic>>> pmLoadOlderFromD1() async {
    if (_pmNoMore || _pmOldestTs == null) return const [];
    return pmGet(before: _pmOldestTs!, limit: 200);
  }

  /// Restores group history from the *ephemeral-key* D1 inbox: group messages
  /// other members sent are gift-wrapped to our per-group ephemeral keys and
  /// deposited under those keys, so they only rehydrate via a `pm-get` keyed by
  /// `pubkeys` (NOT our real pubkey). Mirrors `_recoverEphemeralHistory`
  /// (relays.js:2631): a PUBLIC read (no `since` gate — gift-wrap `created_at`
  /// is randomized per NIP-59 so a floor would drop most wraps), chunked to the
  /// server's 200-pubkey cap.
  ///
  /// Returns the parsed wrap events sorted oldest-to-newest, deduped against the
  /// session's processed-id set so a wrap already restored (e.g. via `pm-get`
  /// for wraps addressed to us) isn't re-applied. Unlike the other PM-archive
  /// reads this runs for ephemeral identities too — the `pubkeys` form is an
  /// unauthenticated public read and group ephemeral keys exist regardless of
  /// the login method.
  Future<List<Map<String, dynamic>>> pmGetByPubkeys(
    List<String> pubkeys,
  ) async {
    final keys = <String>[];
    final seen = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !seen.add(pk)) continue;
      keys.add(pk);
    }
    if (keys.isEmpty) return const [];
    final events = <Map<String, dynamic>>[];
    for (var i = 0; i < keys.length; i += 200) {
      final end = (i + 200) < keys.length ? i + 200 : keys.length;
      final chunk = keys.sublist(i, end);
      StorageStream stream;
      try {
        // Public read (withAuth === false in the PWA): no `pubkey`/`auth`.
        stream = await _api.storageStream({
          'action': 'pm-get',
          'pubkeys': chunk,
        });
      } catch (_) {
        continue;
      }
      for (final item in stream.items) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String || id.isEmpty) continue;
        if (_archivedIds.contains(id)) continue;
        _archivedIds.add(id);
        events.add(Map<String, dynamic>.from(item));
      }
    }
    _trim(_archivedIds);
    events.sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
    return events;
  }

  // ===========================================================================
  // Channel archive (D1 `channel-get`) — public read, no auth.
  // ===========================================================================

  /// Per-channel "last fetched" wall-clock (ms), keyed by lowercased channel
  /// name (`_channelD1FetchedAt`, channels.js:1118). Throttles re-fetches.
  final Map<String, int> _channelFetchedAt = {};

  /// Restores recent channel history from the D1 archive (`channel-get`) for
  /// [channelNames] (geohash or named-channel keys, the PWA's `geohash ||
  /// channel`). Mirrors `channelRestoreManyFromD1` (channels.js:1115):
  ///   - lowercases + de-dups the names,
  ///   - skips any fetched within the last 60s unless [force],
  ///   - caps the batch at 50 channels,
  ///   - issues one `_storageApiStream('channel-get', { channels }, false)`
  ///     (a PUBLIC read — no `pubkey`/`auth`).
  ///
  /// Returns the parsed archived events (channel messages, reactions, edits) in
  /// the order the worker streamed them. The caller replays each through the
  /// same ingest pipeline live relay events use (so dedup by id, ordering, and
  /// cosmetics all apply). Failures resolve to an empty list (best-effort; the
  /// live subscription still backfills).
  Future<List<Map<String, dynamic>>> channelGet(
    List<String> channelNames, {
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final names = <String>[];
    final seen = <String>{};
    for (final raw in channelNames) {
      if (raw.isEmpty) continue;
      final name = raw.toLowerCase();
      if (!seen.add(name)) continue;
      if (!force && (_channelFetchedAt[name] ?? 0) > now - 60000) continue;
      _channelFetchedAt[name] = now;
      names.add(name);
      if (names.length >= 50) break;
    }
    if (names.isEmpty) return const [];
    StorageStream stream;
    try {
      // channel-get is a PUBLIC read (withAuth === false, channels.js:1136).
      stream = await _api.storageStream({
        'action': 'channel-get',
        'channels': names,
      });
    } catch (_) {
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      events.add(Map<String, dynamic>.from(item));
    }
    return events;
  }

  /// Purges a NIP-09-deleted channel message from the D1 archive
  /// (`channel-delete`, storage.js:1123-1150). A PUBLIC call — the signed
  /// kind-5 [deletionEvent] IS the authorization (the worker verifies its
  /// signature and deletes only rows authored by its pubkey whose ids appear
  /// in the `e` tags). [channel] is the channel name WITHOUT the leading `#`
  /// (the PWA passes `key.slice(1)`, nostr-core.js:1874-1876). Best-effort.
  Future<void> channelDelete(
    String channel,
    Map<String, dynamic> deletionEvent,
  ) async {
    if (channel.isEmpty) return;
    try {
      // Public: no pubkey/auth (`_storageApiRequest('channel-delete', …, false)`).
      await _api.storageAction({
        'action': 'channel-delete',
        'channel': channel,
        'deletionEvent': deletionEvent,
      });
    } catch (_) {
      // Best-effort purge.
    }
  }

  // ===========================================================================
  // Channel activity discovery (D1 `channel-active`/`channel-active-named` +
  // `channel-activity`) — all PUBLIC reads, no auth. Mirrors channels.js
  // `fetchGeohashActivityFromD1` / `fetchNamedChannelActivityFromD1`.
  // ===========================================================================

  /// A `{ activity, last }` channel-activity result: `activity` maps a channel
  /// name → 24 hourly buckets (index 0 = current hour), `last` maps a channel
  /// name → its last-activity unix-seconds timestamp. The shape is shared by
  /// `channel-active`, `channel-active-named` and `channel-activity`
  /// (storage.js:1086/1102/1118).
  final Map<String, List<int>> _emptyActivity = const {};

  /// Discovers recently-active GEOHASH channels (kind 20000) from D1
  /// (`channel-active`, storage.js:1092) so the sidebar/explorer can surface
  /// channels the client has never opened. PUBLIC read (`withAuth === false`,
  /// channels.js:150) — no `pubkey`/`auth`. Returns `{activity, last}`; failures
  /// resolve to empty maps (best-effort, like the PWA's `.catch(() => null)`).
  Future<ChannelActivityResult> channelActive() =>
      _channelDiscover('channel-active');

  /// Discovers recently-active NAMED channels (kind 23333) from D1
  /// (`channel-active-named`, storage.js:1108). PUBLIC read (channels.js:305).
  /// Same `{activity, last}` shape as [channelActive].
  Future<ChannelActivityResult> channelActiveNamed() =>
      _channelDiscover('channel-active-named');

  Future<ChannelActivityResult> _channelDiscover(String action) async {
    Map<String, dynamic> data;
    try {
      // Public read: no pubkey/auth (channels.js passes withAuth === false).
      data = await _api.storageAction({'action': action});
    } catch (_) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Per-name "last fetched" wall-clock (ms) for the spam-aware activity probe,
  /// mirroring the PWA's 30s throttle on `fetchGeohashActivityFromD1` /
  /// `fetchNamedChannelActivityFromD1`. The discovery calls themselves are
  /// edge-cached server-side so only the batched `channel-activity` lookup is
  /// throttled here, against the union of requested names.
  int _activityFetchedAt = 0;

  /// Fetches lightweight recent-activity counts for many [channelNames] at once
  /// (`channel-activity`, storage.js:1048) so the sidebar can seed unread badges
  /// from the D1 archive. PUBLIC read (channels.js:151) — no `pubkey`/`auth`.
  /// Lowercases + de-dups the names and caps the batch at the server's 200-name
  /// limit. Throttled to one fetch per 30s unless [force]. Returns
  /// `{activity, last}` (empty on failure / empty input).
  Future<ChannelActivityResult> channelActivity(
    List<String> channelNames, {
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _activityFetchedAt != 0 && now - _activityFetchedAt < 30000) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    final names = <String>[];
    final seen = <String>{};
    for (final raw in channelNames) {
      if (raw.isEmpty) continue;
      final name = raw.toLowerCase();
      if (!seen.add(name)) continue;
      names.add(name);
      if (names.length >= 200) break; // server caps at 200 (storage.js:1052)
    }
    if (names.isEmpty) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    _activityFetchedAt = now;
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'channel-activity',
        'channels': names,
      });
    } catch (_) {
      _activityFetchedAt = 0; // allow a retry on transport failure
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Parses a `{activity:{name:[24]}, last:{name:tsSec}}` channel-activity
  /// response into a [ChannelActivityResult]. Lowercases names; coerces bucket
  /// entries + last timestamps to ints; tolerates a malformed/absent field.
  static ChannelActivityResult _parseActivity(Map<String, dynamic> data) {
    final activity = <String, List<int>>{};
    final rawAct = data['activity'];
    if (rawAct is Map) {
      rawAct.forEach((name, buckets) {
        if (buckets is! List) return;
        activity[name.toString().toLowerCase()] = [
          for (final b in buckets) (b is num) ? b.toInt() : 0,
        ];
      });
    }
    final last = <String, int>{};
    final rawLast = data['last'];
    if (rawLast is Map) {
      rawLast.forEach((name, ts) {
        if (ts is num && ts > 0) last[name.toString().toLowerCase()] = ts.toInt();
      });
    }
    return ChannelActivityResult(activity: activity, last: last);
  }

  // ===========================================================================
  // Custom-emoji archive (D1 `emoji-get`) — emoji.js `_emojiRestoreFromD1`.
  // ===========================================================================

  /// Wall-clock (ms) of the last `emoji-get` fetch — the PWA re-fetches at
  /// most every 10 minutes (`_emojiD1FetchedAt`, emoji.js:202-203).
  int _emojiFetchedAt = 0;

  /// Hydrates the deduped NIP-30 emoji set from the D1 archive (`emoji-get`,
  /// storage.js:1168-1198): a PUBLIC NDJSON stream of the archived kind-30030
  /// packs plus our own kind-10030 pack list. Mirrors `_emojiRestoreFromD1`
  /// (emoji.js:198-222): throttled to one fetch per 10 minutes (reset on
  /// transport failure so the next attempt retries); the caller replays each
  /// returned event through the same ingest path live relay 30030/10030
  /// events take. Returns the raw events; failures resolve to an empty list.
  Future<List<Map<String, dynamic>>> emojiGet({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _emojiFetchedAt != 0 && now - _emojiFetchedAt < 600000) {
      return const [];
    }
    _emojiFetchedAt = now;
    StorageStream stream;
    try {
      // Public read (`_storageApiStream('emoji-get', {}, false)`). The pubkey
      // rides the body so the worker can append our own 10030 line
      // (storage.js:1170/1186-1194); over the authed `/api` socket it is
      // pinned server-side exactly like the PWA.
      stream = await _api.storageStream({
        'action': 'emoji-get',
        'pubkey': _pubkey,
      });
    } catch (_) {
      _emojiFetchedAt = 0; // allow a retry (emoji.js:208)
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      events.add(Map<String, dynamic>.from(item));
    }
    return events;
  }

  // ===========================================================================
  // Zap-receipt archive (D1 `zap-put` / `zap-get`) — zaps.js:29-93.
  // ===========================================================================

  /// Uploads validated kind-9735 zap receipts to the D1 archive (`zap-put`,
  /// storage.js:1328-1350; authed, ≤100 events per call — the caller batches).
  /// The worker classifies each receipt by the `k` tag inside its
  /// `description` (20000/23333→channel, 1059→pm, 0→profile) and re-verifies
  /// the signature server-side. Best-effort; failures are swallowed (the
  /// caller's queue re-flushes).
  Future<bool> zapPut(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return false;
    try {
      await _api.storageAction({
        'action': 'zap-put',
        'pubkey': _pubkey,
        'events': events.take(100).toList(),
        'auth': await _auth('zap-put'),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Backfills archived kind-9735 receipts for the given zapped-message [ids]
  /// (`zap-get`, storage.js:1286-1326 — a PUBLIC NDJSON stream, no auth, ≤500
  /// ids). [scope] is `'pm'` or `'channel'` (anything else is coerced to
  /// channel server-side); profile-scope receipts are keyed on the recipient
  /// pubkey, so pass the pubkey as the id with scope `'channel'`'s DB —
  /// mirroring `_backfillZapReceiptsFromD1([pubkey], 'profile')`, which the
  /// worker also serves from the channels DB. Returns the raw receipt events;
  /// failures resolve to an empty list.
  Future<List<Map<String, dynamic>>> zapGet(
    String scope,
    List<String> ids,
  ) async {
    final clean = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.toLowerCase();
      if (!_isHex64(id) || !seen.add(id)) continue;
      clean.add(id);
      if (clean.length >= 500) break; // server caps at 500 (storage.js:1292)
    }
    if (clean.isEmpty) return const [];
    StorageStream stream;
    try {
      // Public read: no pubkey/auth (`_storageApiStream('zap-get', …, false)`).
      stream = await _api.storageStream({
        'action': 'zap-get',
        'scope': scope,
        'ids': clean,
      });
    } catch (_) {
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      events.add(Map<String, dynamic>.from(item));
    }
    return events;
  }

  // ===========================================================================
  // Other users' active shop items (D1 `shop-status`) — PUBLIC read, no auth.
  // Mirrors shop.js `_flushShopStatusQueue` (the batched cosmetics lookup that
  // backs `getUserShopItems(pubkey)` / `getFlairForUser(pubkey)`).
  // ===========================================================================

  /// Batch-reads other users' active shop items from D1 (`shop-status`,
  /// storage.js:206). PUBLIC read (`withAuth === false`, shop.js:457) — no
  /// `pubkey`/`auth`. Caps the batch at the server's 100-pubkey limit and
  /// lowercases/validates the keys (storage.js:207-212). [fresh] forces a cache
  /// bypass on the server for those pubkeys (the PWA's `shop-update`-driven
  /// `invalidateShopCache`, shop.js:453); only pubkeys also present in [pubkeys]
  /// matter.
  ///
  /// Returns a map of pubkey → [ShopStatus] (`active` items + `updatedAt`) for
  /// every pubkey the server reported. Failures resolve to an empty map
  /// (best-effort; the PWA swallows the error and keeps the cached items).
  Future<Map<String, ShopStatus>> shopStatus(
    List<String> pubkeys, {
    List<String> fresh = const [],
  }) async {
    final pks = <String>[];
    final seen = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !seen.add(pk)) continue;
      pks.add(pk);
      if (pks.length >= 100) break; // server caps at 100 (storage.js:207)
    }
    if (pks.isEmpty) return const {};
    final freshPks = <String>[];
    final freshSeen = <String>{};
    for (final raw in fresh) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !freshSeen.add(pk)) continue;
      if (seen.contains(pk)) freshPks.add(pk);
    }
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'shop-status',
        'pubkeys': pks,
        if (freshPks.isNotEmpty) 'fresh': freshPks,
      });
    } catch (_) {
      return const {};
    }
    final statuses = data['statuses'];
    if (statuses is! Map) return const {};
    final out = <String, ShopStatus>{};
    statuses.forEach((pk, st) {
      if (pk is! String || st is! Map) return;
      out[pk.toLowerCase()] = ShopStatus.fromJson(st.cast<String, dynamic>());
    });
    return out;
  }

  // ===========================================================================
  // Helpers.
  // ===========================================================================

  /// The NIP-98 (kind-27235) auth event the worker's `verifyClientAuth`
  /// expects, bound to the storage endpoint + action (built via [Nip98Auth] in
  /// the ApiClient; the PWA signs the same event in `_signBotAuth`). Returns the
  /// signed event JSON for `body.auth`.
  ///
  /// Signs a kind-27235 auth event for [action] via the injected builder. Async
  /// because the builder signs through the active [EventSigner] — a NIP-46
  /// remote signer round-trips the `sign_event` RPC. Returns null when there's
  /// no builder or signing fails (auth then omitted; tolerated best-effort).
  Future<Map<String, dynamic>?> _auth(String action) async =>
      _authBuilder == null ? null : await _authBuilder!(action);

  /// Auth-event builder injected by the controller (which holds the signer).
  /// Returns the signed kind-27235 event JSON, or null. Async so it can sign via
  /// a NIP-46 remote signer (the PWA's `_signBotAuth` → `signEvent` dispatch).
  /// When null (e.g. pure tests of body shape via a pre-signed auth), callers
  /// pass `auth` themselves. Set via [setAuthBuilder].
  Future<Map<String, dynamic>?> Function(String action)? _authBuilder;

  /// Registers the async auth builder. The controller wires this to a signed
  /// kind-27235 event via the active signer — local OR NIP-46 remote, so durable
  /// remote-signer accounts now authenticate their settings/PM sync too.
  void setAuthBuilder(
    Future<Map<String, dynamic>?> Function(String action) builder,
  ) {
    _authBuilder = builder;
  }

  Future<String?> _encryptToSelf(String plaintext) async {
    try {
      return await _signer.nip44Encrypt(_pubkey, plaintext);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _decryptFromSelf(String ciphertext) async {
    try {
      return await _signer.nip44Decrypt(_pubkey, ciphertext);
    } catch (_) {
      return null;
    }
  }

  static String _sha256Hex(String s) =>
      sha256.convert(utf8.encode(s)).toString();

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  static bool _addressedTo(Map<String, dynamic> wrap, String pubkey) {
    final tags = wrap['tags'];
    if (tags is! List) return false;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p' && t[1] == pubkey) {
        return true;
      }
    }
    return false;
  }

  static String? _recipientOf(Map<String, dynamic> wrap) {
    final tags = wrap['tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p') {
        final v = t[1];
        if (v is String && _isHex64(v.toLowerCase())) return v.toLowerCase();
      }
    }
    return null;
  }

  static int _createdAt(Map<String, dynamic> ev) =>
      (ev['created_at'] as num?)?.toInt() ?? 0;

  static void _trim(Set<String> ids) {
    if (ids.length <= 6000) return;
    final keep = ids.toList().sublist(ids.length - 4000);
    ids
      ..clear()
      ..addAll(keep);
  }

  /// The storage endpoint URL the NIP-98 `u`-tag must bind to.
  static String storageUrl() => 'https://${ApiConfig.apiHost}/api/storage';
}

/// A decoded settings category (real category + decrypted payload + updatedAt).
class _DecodedCategory {
  _DecodedCategory({
    required this.category,
    required this.payload,
    required this.updatedAt,
  });
  final String category;
  final Map<String, dynamic> payload;
  final int updatedAt;
}

/// The result of [StorageSync.settingsGet]: the merged synced-settings payload
/// and the newest `updatedAt` (ms) across the applied core sections. The caller
/// applies [payload] only when [newestTs] is newer than the stored
/// `nym_last_settings_sync_ts`.
class SettingsLoadResult {
  const SettingsLoadResult({
    required this.payload,
    required this.newestTs,
    this.notificationsPayload,
    this.readStatePayload,
    this.groupConversations,
    this.groupEphemeralKeys = const {},
    this.groupMessageHistory = const {},
  });
  final Map<String, dynamic> payload;
  final int newestTs;

  /// Decoded `nymchat-groups` category: `groupId → serialized group` (the
  /// PWA's `groupConversations` sync map, settings.js `_buildGroupConversationsSync`).
  /// Null when no group-conversation category was present. Applied additively /
  /// monotonically regardless of the core-section ts gate (the PWA runs it
  /// through `applyNostrSettingsAdditive`, settings.js:812-816).
  final Map<String, dynamic>? groupConversations;

  /// Decoded + merged `nymchat-keys-<gid>` categories: `groupId → serialized
  /// ephemeral-key entry`. Each per-group category is a separate D1 row (the
  /// PWA publishes one wrap per group, settings.js:435-461); they are merged
  /// here into a single map for the caller.
  final Map<String, dynamic> groupEphemeralKeys;

  /// Decoded + merged `nymchat-history-<gid>-<bucket>-<shard>` categories:
  /// `group-<gid> → [message maps]`. The PWA shards a group's backlog across
  /// month-bucketed, byte-bounded wraps (settings.js:495-529); the shards for a
  /// conversation key are concatenated here.
  final Map<String, List<dynamic>> groupMessageHistory;

  /// The decrypted `nymchat-notifications` wrap payload (N26), when present —
  /// carries `seenNotifications` (the cross-device notification read-state map).
  /// Surfaced separately from the settings [payload] because the caller merges
  /// it additively (idempotently) regardless of the settings ts gate.
  final Map<String, dynamic>? notificationsPayload;

  /// The decrypted `nymchat-readstate` category payload, when present — carries
  /// `channelLastRead` (the per-channel/PM/group read watermarks another device
  /// published). Surfaced separately from the core settings [payload] because
  /// the PWA applies non-core categories additively via
  /// `applyNostrSettingsAdditive` (settings.js:815-819) BEFORE and independent
  /// of the core-section ts gate, so cross-device unread state syncs even when
  /// no core setting changed.
  final Map<String, dynamic>? readStatePayload;
}

/// An inbound settings-transfer offer (one synced settings section another
/// device published, newer than this device's last sync). The list UI shows
/// these as accept/decline rows; accepting applies [payload] via the settings
/// controller and advances the sync ts.
class SettingsTransferOffer {
  const SettingsTransferOffer({
    required this.id,
    required this.section,
    required this.payload,
    required this.updatedAt,
  });

  /// Stable id (the D1 category, e.g. `nymchat-settings-appearance`) — used as
  /// the accept/decline key.
  final String id;

  /// The settings-modal section name (`appearance`, `privacy`, …) or the raw
  /// category for the legacy monolithic blob.
  final String section;

  /// The decoded payload (PWA field names, `__cat` removed).
  final Map<String, dynamic> payload;

  /// The category's `updatedAt` in ms (D1 wall-clock of the publishing device).
  final int updatedAt;
}

/// The result of a channel-activity D1 read ([StorageSync.channelActive] /
/// [StorageSync.channelActiveNamed] / [StorageSync.channelActivity]). [activity]
/// maps a lowercased channel name → 24 hourly buckets (index 0 = current hour);
/// [last] maps a lowercased channel name → its last-activity unix-seconds
/// timestamp. Mirrors the `{activity, last}` payload (storage.js:1086).
class ChannelActivityResult {
  const ChannelActivityResult({required this.activity, required this.last});

  /// Channel name → 24 hourly message-count buckets (kind 20000/23333 only).
  final Map<String, List<int>> activity;

  /// Channel name → last-activity timestamp in unix seconds.
  final Map<String, int> last;

  bool get isEmpty => activity.isEmpty && last.isEmpty;
}

/// Another user's active shop items from a `shop-status` D1 read
/// (storage.js:226-237): the `active` cosmetics record + the record's
/// `updatedAt` (used to skip a re-render when nothing changed, shop.js:471).
class ShopStatus {
  const ShopStatus({required this.active, required this.updatedAt});

  final ShopStatusActive active;
  final int updatedAt;

  factory ShopStatus.fromJson(Map<String, dynamic> j) => ShopStatus(
        active: ShopStatusActive.fromJson(
          (j['active'] as Map?)?.cast<String, dynamic>(),
        ),
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// The `active` block of a `shop-status` record — the same `{style, flair,
/// cosmetics, supporter, editions}` shape the owner publishes via
/// `shop-set-active` (storage.js:308-314, read back at shop.js:459-467).
class ShopStatusActive {
  const ShopStatusActive({
    this.style,
    this.flair = const [],
    this.cosmetics = const [],
    this.supporter = false,
    this.editions = const {},
  });

  /// Active message-style item id, or null.
  final String? style;

  /// Active nickname-flair item ids (the PWA renders the last, shop.js:401).
  final List<String> flair;

  /// Active special-cosmetic ids.
  final List<String> cosmetics;

  /// True when the supporter badge is active.
  final bool supporter;

  /// Numbered-edition map (item id → edition number, e.g. Genesis #42).
  final Map<String, int> editions;

  factory ShopStatusActive.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ShopStatusActive();
    return ShopStatusActive(
      style: j['style'] is String ? j['style'] as String : null,
      flair: (j['flair'] as List?)?.whereType<String>().toList() ?? const [],
      cosmetics:
          (j['cosmetics'] as List?)?.whereType<String>().toList() ?? const [],
      supporter: j['supporter'] == true,
      editions: (j['editions'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), (v is num) ? v.toInt() : 0),
          ) ??
          const {},
    );
  }
}

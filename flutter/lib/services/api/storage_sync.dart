import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show compute, kIsWeb;

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nym_sync_builder.dart';
import '../../models/settings.dart';
import '../../features/chat_tools/chat_tools.dart'
    show ChatToolsKeys, trimSavedPayload;
import '../../features/chat_nav/chat_nav.dart' show ChatNavKeys, trimPinnedPayload;
import '../../features/chat_lock/chat_lock.dart'
    show ChatLockKeys, trimLockedPayload;
import '../../features/groups/group_logic.dart'
    show kPmDepositQueueMax, kPmDepositFlushMs, kPmDepositFlushJitterMs,
        kPmDepositBacklogMs, kPmDepositBatchMin, kPmDepositBatchMax;
import '../../core/crypto/pq.dart' as pq;
import '../../features/identity/pq_registry.dart'
    show pqRootCandidates, pqSelfCandidates;
import '../../features/identity/pq_root.dart';
import '../nostr/event_signer.dart';
import '../storage/key_value_store.dart';
import 'api_client.dart';
import 'api_config.dart';

const int kPmDepositRetryBaseMs = 2000;

const int kPmDepositRetryMaxMs = 120000;

const int kPmDepositMaxAttempts = 5;

/// Cross-device `/api/storage` sync (settings, profile mirror, PM archive); every call is lazy and best-effort.
class StorageSync {
  StorageSync({
    required this._api,
    required this._signer,
    required String pubkey,
    required bool durableIdentity,
    this._kv,
    DateTime Function()? now,
  })  : _pubkey = pubkey.toLowerCase(),
        _durable = durableIdentity,
        _now = now ?? DateTime.now;

  final DateTime Function() _now;

  final ApiClient _api;
  final EventSigner _signer;
  final String _pubkey;

  /// KV store for synced prefs; null restricts the payload to the typed [Settings] subset.
  final KeyValueStore? _kv;

  /// Lazily opened fallback for [_kv], so legacy construction doesn't publish a stripped payload.
  KeyValueStore? _openedKv;
  bool _kvOpenAttempted = false;

  Future<KeyValueStore?> _kvOrOpen() async {
    if (_kv != null) return _kv;
    if (!_kvOpenAttempted) {
      _kvOpenAttempted = true;
      try {
        _openedKv = await KeyValueStore.open();
      } catch (_) {
        // No SharedPreferences backend: keep the typed-[Settings] subset.
      }
    }
    return _openedKv;
  }

  /// True for a logged-in identity; ephemeral identities skip the durable PM archive.
  final bool _durable;

  bool get durableIdentity => _durable;

  // Synced vs device-local settings

  /// Section to keys map (PWA `NYM_SETTINGS_SECTION_KEYS`); each section is its own encrypted category, else `misc`.
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
      // Filed under `appearance` as in the PWA, so it never lives in two categories.
      'uiLanguage',
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
    ],
    'messaging': [
      'groupChatPMOnlyMode',
      'threadsEnabled',
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
      'swipeReactEmojiTs',
      'notificationsEnabled',
      'groupNotifyMentionsOnly',
      'threadNotifyMentionsOnly',
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
      'backgroundConnectivity',
      'cachePMs',
      'tutorialSeen',
      'botPmWelcomed',
      'botPmClearedAt',
      'botMaxRuns',
    ],
  };

  /// Only identity key material stays device-local; no key, salt or credential leaves the device.
  static const Set<String> deviceLocalKeys = {
    'vault', // Keypair/secret material never leaves the device.
  };

  /// Routing category `nymchat-settings-<section>`, carried inside the blob as `__cat`.
  static String sectionCategory(String section) => 'nymchat-settings-$section';

  /// Opaque per-account D1 column `nymchat-<sha256("<pubkey>:d1:<dTag>")>`, hiding group membership.
  String d1Category(String dTag) =>
      'nymchat-${_sha256Hex('$_pubkey:d1:$dTag')}';

  // Encrypted settings sync

  /// Per-section payloads with PWA field names and `v: 2`; [kv], [extras] and landing/seen-call inputs are optional.
  static Map<String, Map<String, dynamic>> buildSectionPayloads(
    Settings s, {
    String? pinnedLandingChannelJson,
    Map<String, dynamic>? seenCalls,
    KeyValueStore? kv,
    String? selfPubkey,
    Map<String, dynamic>? extras,
  }) {
    // The flat synced payload with PWA field names.
    final flat = <String, dynamic>{
      'theme': s.theme.id,
      'sound': s.sound,
      'autoscroll': s.autoscroll,
      'showTimestamps': s.showTimestamps,
      'timeFormat': s.timeFormat,
      'dateFormat': s.dateFormat,
      'chatLayout': s.chatLayout,
      'chatViewMode': s.chatViewMode,
      'columnsLayout': kv != null
          ? _kvJsonList(kv, StorageKeys.columnsLayout)
          : const <dynamic>[],
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
      'threadsEnabled': s.threadsEnabled,
      'translateLanguage': s.translateLanguage,
      'gesturesEnabled': s.gesturesEnabled,
      'swipeLeftAction': s.swipeLeftAction,
      'swipeRightAction': s.swipeRightAction,
      'swipeThreshold': s.swipeThreshold,
      'swipeReactEmoji': s.swipeReactEmoji,
      'notificationsEnabled': s.notificationsEnabled,
      'syncMLSHistory': s.syncMLSHistory,
      'sortByProximity': s.sortByProximity,
      'hideNonPinned': s.hideNonPinned,
      'lowDataMode': s.lowDataMode,
      'backgroundConnectivity': s.backgroundConnectivity,
      'cachePMs': s.cachePMs,
    };

    if (kv != null) {
      // KV-backed synced prefs; image blur syncs as true | false | 'friends'.
      flat['blurOthersImages'] = _blurForSync(kv, selfPubkey);
      flat['wallpaperCustomUrl'] =
          kv.getString(StorageKeys.wallpaperCustomUrl) ?? '';
      // Sidebar order falls back to the default section ids.
      flat['sidebarSectionOrder'] = _sidebarOrderForSync(kv);
      // Moderation and social lists, stored as JSON arrays in KV.
      flat['blockedUsers'] = _kvJsonList(kv, StorageKeys.blocked);
      flat['friends'] = _kvJsonList(kv, StorageKeys.friends);
      flat['blockedKeywords'] = _kvJsonList(kv, StorageKeys.blockedKeywords);
      flat['blockedChannels'] = _kvJsonList(kv, StorageKeys.blockedChannels);
      flat['hiddenChannels'] = _kvJsonList(kv, StorageKeys.hiddenChannels);
      flat['pinnedChannels'] = _kvJsonList(kv, StorageKeys.pinnedChannels);
      flat['userJoinedChannels'] =
          _kvJsonList(kv, StorageKeys.userJoinedChannels);
      // Closed-PM and left-group read state.
      flat['closedPMs'] = _kvJsonList(kv, StorageKeys.closedPms);
      flat['leftGroups'] = const <dynamic>[];
      flat['closedPMTimes'] = _kvJsonMap(kv, StorageKeys.closedPmTimes);
      flat['leftGroupTimes'] = <String, dynamic>{};
      // Per-pubkey lightning address, falling back to the global key, so a null never overwrites another device's.
      flat['lightningAddress'] = selfPubkey == null
          ? kv.getString(StorageKeys.lightningAddressGlobal)
          : kv.getString(StorageKeys.lightningAddressFor(selfPubkey)) ??
              kv.getString(StorageKeys.lightningAddressGlobal);
      flat['powDifficulty'] =
          kv.getInt(StorageKeys.powDifficulty, defaultValue: 0);
      // keypairMode is device-local and never synced; only the non-sensitive at-rest hint is.
      flat['encryptAtRestPreferred'] =
          kv.getBool(StorageKeys.encryptAtRestPref);
      flat['translateFavoriteLanguages'] =
          _kvJsonList(kv, StorageKeys.translateFavorites);
      flat['emojiPackFavorites'] =
          _kvJsonList(kv, StorageKeys.emojiPackFavorites);
      flat['emojiCategoryFavorites'] =
          _kvJsonList(kv, StorageKeys.emojiCategoryFavorites);
      final gifs = _favoriteGifsForSync(kv);
      if (gifs.isNotEmpty) {
        // Absent when empty, as in the PWA.
        flat['favoriteGifs'] = gifs;
      }
      flat['recentEmojis'] =
          _kvJsonList(kv, StorageKeys.recentEmojis).take(24).toList();
      // Publish swipe-react only for a real pick, with its timestamp, so defaults never clobber another device.
      if ((kv.getString(StorageKeys.swipeReactEmoji) ?? '').isEmpty) {
        flat.remove('swipeReactEmoji');
      } else {
        flat['swipeReactEmojiTs'] =
            kv.getInt(StorageKeys.swipeReactEmojiTs, defaultValue: 0);
      }
      flat['groupNotifyMentionsOnly'] =
          kv.getString(StorageKeys.groupNotifyMentionsOnly) == 'true';
      flat['threadNotifyMentionsOnly'] =
          kv.getString(StorageKeys.threadNotifyMentionsOnly) == 'true';
      flat['notifyFriendsOnly'] =
          kv.getString(StorageKeys.notifyFriendsOnly) == 'true';
      flat['tutorialSeen'] = kv.getString(StorageKeys.tutorialSeen) == 'true';
      flat['botPmWelcomed'] = kv.getString(StorageKeys.botpmWelcomed) == 'true';
      flat['botPmClearedAt'] =
          kv.getInt(StorageKeys.botpmClearedAt, defaultValue: 0);
      flat['botMaxRuns'] = kv.getInt(StorageKeys.botpmMaxRuns, defaultValue: 0);
    }

    // Landing channel: threaded JSON, then KV, then the PWA default; omitted without [kv] when invalid.
    final landing = _parsePinnedLandingChannel(pinnedLandingChannelJson) ??
        (kv == null
            ? null
            : _parsePinnedLandingChannel(
                    kv.getString(StorageKeys.pinnedLandingChannel)) ??
                {'type': 'geohash', 'geohash': 'nymchat'});
    if (landing != null) {
      flat['pinnedLandingChannel'] = landing;
    }

    // Seen-call map `{callId: {t,s}}` in `messaging` when the caller passes one.
    if (seenCalls != null) {
      flat['seenCalls'] = seenCalls;
    }

    // Controller-owned state overrides the defaults above.
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

  /// `showStatus` on the wire: `true | false | 'friends'`.
  static dynamic _showStatusForSync(String showStatus) {
    if (showStatus == 'false') return false;
    if (showStatus == 'friends') return 'friends';
    return true;
  }

  /// Decodes a KV JSON array; anything else is empty.
  static List<dynamic> _kvJsonList(KeyValueStore kv, String key) {
    final raw = kv.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {
      // Corrupt JSON: treat as empty.
    }
    return const [];
  }

  /// Decodes a KV JSON object; anything else is empty.
  static Map<String, dynamic> _kvJsonMap(KeyValueStore kv, String key) {
    final raw = kv.getString(key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Corrupt JSON: treat as empty.
    }
    return <String, dynamic>{};
  }

  /// Image-blur wire value: per-pubkey key, then global, defaulting to blur.
  static dynamic _blurForSync(KeyValueStore kv, String? selfPubkey) {
    String? v;
    if (selfPubkey != null && selfPubkey.isNotEmpty) {
      v = kv.getString(StorageKeys.imageBlurFor(selfPubkey));
    }
    v ??= kv.getString(StorageKeys.imageBlur);
    if (v == null) return true; // Default to blur.
    if (v == 'friends') return 'friends';
    return v == 'true';
  }

  /// Stored sidebar order, else `['channels','pms','nyms']`.
  static List<dynamic> _sidebarOrderForSync(KeyValueStore kv) {
    final stored = _kvJsonList(kv, StorageKeys.sidebarSectionOrder);
    if (stored.isNotEmpty) return stored;
    return const ['channels', 'pms', 'nyms'];
  }

  /// Favorite GIFs normalized to `{url, title}`, capped at 100.
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

  /// Normalized `{type, geohash}` landing channel, or null when absent or invalid; `type` defaults to 'geohash'.
  static Map<String, dynamic>? _parsePinnedLandingChannel(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final m = jsonDecode(trimmed);
      if (m is Map &&
          m['geohash'] is String &&
          (m['geohash'] as String).isNotEmpty) {
        final type = m['type'] is String ? m['type'] as String : 'geohash';
        return {'type': type, 'geohash': m['geohash'] as String};
      }
    } catch (_) {
      // Corrupt JSON: omit rather than poison the channels section.
    }
    return null;
  }

  /// Publishes changed settings sections to D1 encrypted to self with `__cat`; returns the sections sent; never throws.
  Future<Set<String>> settingsSet(
    Settings settings, {
    String? pinnedLandingChannelJson,
    Map<String, dynamic>? seenCalls,
    Map<String, dynamic>? extras,
    Map<String, int>? channelActivity,
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
      // The real category rides inside the blob as `__cat`; only channels carries a trim fn.
      final ok = await _publishCategoryWrap(
        Map<String, dynamic>.of(entry.value),
        sectionCategory(entry.key),
        trim: switch (entry.key) {
          'channels' => _channelsTrimmer(channelActivity ?? const {}),
          'messaging' => trimMessagingSection,
          _ => null,
        },
      );
      if (ok) sent.add(entry.key);
    }
    await publishSettingsChangedPing(sent.toList());
    return sent;
  }

  /// Stable id for this client, so a device ignores its own ping echo.
  String? _syncInstanceIdCache;
  String get syncInstanceId =>
      _syncInstanceIdCache ??= '${Random().nextInt(1 << 32).toRadixString(36)}'
          '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  /// Content-free "settings changed" ping to our other devices over the open self gift-wrap sub; they re-read D1.
  Future<void> publishSettingsChangedPing(List<String> sections) async {
    if (sections.isEmpty) return;
    final publisher = _syncWrapPublisher;
    if (publisher == null) return;
    try {
      await publisher({
        'src': syncInstanceId,
        'sections': sections,
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }, 'nymchat-sync-ping');
    } catch (_) {
      // Best-effort: a failed ping only delays the other device to its next D1 read.
    }
  }

  /// Injected relay `nym-sync` publisher, called after the D1 write with the payload minus `__cat`; null means D1 only.
  Future<void> Function(Map<String, dynamic> payload, String dTag)?
      _syncWrapPublisher;

  void setSyncWrapPublisher(
    Future<void> Function(Map<String, dynamic> payload, String dTag) publisher,
  ) {
    _syncWrapPublisher = publisher;
  }

  /// Last-published payload JSON per d-tag, to skip unchanged categories.
  final Map<String, String> _publishedSectionJson = {};

  // NIP-44 padding is a step function across seal and wrap; modeled exactly, the real rumor cliff is 28,672 bytes.
  static const int _rumorOverhead = 256;
  static const int _relayEventLimit = 65000;

  /// NIP-44 v2 `calc_padded_len`.
  static int nip44PaddedLen(int len) {
    if (len <= 32) return 32;
    final nextPower = 1 << ((log(len - 1) / ln2).floor() + 1);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * (((len - 1) ~/ chunk) + 1);
  }

  /// NIP-44 v2 payload length: base64(version | nonce | ciphertext | mac).
  static int nip44PayloadLen(int plaintextBytes) {
    final raw = 1 + 32 + (2 + nip44PaddedLen(plaintextBytes)) + 32;
    return ((raw + 2) ~/ 3) * 4;
  }

  /// pq2 framing: `pq2.` plus a fixed 1088-byte ML-KEM ciphertext and the AEAD output, all base64url.
  static const int _pq2PrefixLen = 4;
  static const int _mlKemCipherTextBytes = 1088;

  static int _b64uLen(int n) => (n * 4 + 2) ~/ 3;

  static int pq2PayloadLen(int innerLen) =>
      _pq2PrefixLen +
      _b64uLen(_mlKemCipherTextBytes) +
      1 +
      _b64uLen(innerLen + 16);

  /// Size of the final `["EVENT", wrapped]` frame; [pq2] inflates both layers substantially.
  static int wrappedSizeForRumor(int rumorBytes, {bool pq2 = false}) {
    const sealOverhead = 200; // kind/created_at/tags/pubkey/id/sig
    const wrapOverhead = 320; // Same, plus the p/d/k tags.
    int layer(int n) =>
        pq2 ? pq2PayloadLen(nip44PayloadLen(n)) : nip44PayloadLen(n);
    final sealJson = layer(rumorBytes) + sealOverhead;
    return layer(sealJson) + wrapOverhead + 10;
  }

  /// Largest rumor whose wrapped event still clears the relay gate.
  static int maxRumorBytesForWrap(
      [int limit = _relayEventLimit, bool pq2 = false]) {
    var lo = 32, hi = 64 * 1024, best = 32;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (wrappedSizeForRumor(mid, pq2: pq2) <= limit) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  static final int _maxRumorBytesClassical = maxRumorBytesForWrap();
  static final int _maxRumorBytesPq2 =
      maxRumorBytesForWrap(_relayEventLimit, true);

  /// The ceiling for the encryption a self-addressed wrap will actually use.
  int get _maxRumorBytes =>
      _pqSealToSelf ? _maxRumorBytesPq2 : _maxRumorBytesClassical;

  /// Approximate rumor size: UTF-8 length of the double-stringified payload plus overhead.
  static int _rumorByteSize(Map<String, dynamic> payload) =>
      utf8.encode(jsonEncode(jsonEncode(payload))).length + _rumorOverhead;

  /// Under size pressure only, trims joined channels first, then read-state arrays oldest first.
  static bool Function(Map<String, dynamic>) _channelsTrimmer(
      Map<String, int> activity) {
    return (Map<String, dynamic> p) {
      // 1. Least-recently-active joined channels.
      final joined = p['userJoinedChannels'];
      if (joined is List && joined.length > 20) {
        final ordered = joined.map((e) => '$e').toList()
          ..sort((a, b) => (activity[a] ?? 0).compareTo(activity[b] ?? 0));
        var n = (ordered.length * 0.25).floor();
        if (n < 1) n = 1;
        final drop = ordered.take(n).toSet();
        p['userJoinedChannels'] =
            joined.where((e) => !drop.contains('$e')).toList();
        return true;
      }

      // 2. Read-state arrays, oldest first by their companion times map.
      for (final pair in const [
        ('closedPMs', 'closedPMTimes'),
        ('leftGroups', 'leftGroupTimes'),
      ]) {
        final arr = p[pair.$1];
        final rawTimes = p[pair.$2];
        final times = rawTimes is Map ? rawTimes : null;
        if (arr is List && arr.length > 30) {
          num at(String k) {
            final v = times?[k];
            return v is num ? v : 0;
          }

          final ordered = arr.map((e) => '$e').toList()
            ..sort((a, b) => at(a).compareTo(at(b)));
          var n = (ordered.length * 0.25).floor();
          if (n < 1) n = 1;
          final drop = ordered.take(n).toSet();
          p[pair.$1] = arr.where((e) => !drop.contains('$e')).toList();
          // Keep the companion map in step so it cannot outlive its set.
          if (times != null) {
            for (final k in drop) {
              times.remove(k);
            }
          }
          return true;
        }
      }

      // 3. Any time map that outgrew its set, or has no set.
      for (final key in const ['closedPMTimes', 'leftGroupTimes']) {
        final m = p[key];
        if (m is! Map || m.length <= 30) continue;
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
    };
  }

  /// Sheds messaging bulk (GIFs, recent emoji, seen calls, emoji favorites) so the scalars still publish.
  static bool trimMessagingSection(Map<String, dynamic> p) {
    for (final key in const [
      'favoriteGifs',
      'recentEmojis',
      'seenCalls',
      'emojiPackFavorites',
      'emojiCategoryFavorites',
    ]) {
      final v = p[key];
      final isEmpty = (v is List && v.isEmpty) ||
          (v is Map && v.isEmpty) ||
          v == null;
      if (isEmpty) continue;
      p.remove(key);
      return true;
    }
    return false;
  }

  /// Drops the oldest ~10% of the synced bell history.
  static bool _trimOldestNotifications(Map<String, dynamic> p) {
    final arr = p['notificationHistory'];
    if (arr is! List || arr.length <= 1) return false;
    final drop = (arr.length * 0.1).ceil().clamp(1, arr.length);
    p['notificationHistory'] = arr.sublist(drop);
    return true;
  }

  /// Notifications trim chain: history first, then seen keys, one trim per round.
  static bool _trimNotifications(Map<String, dynamic> p) =>
      _trimOldestNotifications(p) || _trimOldestSeen(p);

  /// Drops the oldest 25% of seen-notification keys.
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

  /// Publishes a D1 blob plus relay wrap, trimming to fit (≤500 rounds) and skipping unchanged; returns whether D1 was sent.
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

    payload = _mergeUnknownSectionKeys(dTag, payload);
    final json = jsonEncode(payload);
    if (_publishedSectionJson[dTag] == json) return false; // unchanged

    final ok = await _setSettingsCategory(
      d1Category(dTag),
      jsonEncode(_withCat(payload, dTag)),
    );
    // Mark published only after success, or a failed write is never retried.
    if (!ok) {
      _publishedSectionJson.remove(dTag);
      return false;
    }
    _publishedSectionJson[dTag] = json;

    // The relay wrap is best-effort; D1 is what restores read back.
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

  final Map<String, Map<String, dynamic>> _lastInboundSections = {};

  /// Carries forward keys from the last inbound payload that we don't write, so the other client's settings survive.
  Map<String, dynamic> _mergeUnknownSectionKeys(
      String dTag, Map<String, dynamic> payload) {
    final prev = _lastInboundSections[dTag];
    if (prev == null || prev.isEmpty) return payload;
    final out = Map<String, dynamic>.from(payload);
    for (final e in prev.entries) {
      if (e.key == 'v' || e.key == '__cat') continue;
      out.putIfAbsent(e.key, () => e.value);
    }
    return out;
  }

  /// Last inbound `nymchat-notifications` payload, so writes carry another device's bell state forward.
  Map<String, dynamic>? _lastInboundNotifications;

  // Post-quantum root record

  Map<String, dynamic>? _lastInboundPqRoot;

  /// Whether a settings read completed this session; no record and could-not-look differ.
  bool _pqRootLoadSucceeded = false;

  /// Whether the account has a root record, from the D1 column list even if undecryptable.
  bool _pqRootRowPresent = false;

  /// Rows sealed to a root this device lacks; saving stays off so defaults don't replace them.
  bool _settingsRestoreUnreadable = false;

  bool get settingsRestoreUnreadable => _settingsRestoreUnreadable;

  /// Whether this device is locked out of the account's root, set by the controller.
  bool _pqRootLockedOut = false;

  /// Rows the last completed load could not open, for recomputing the verdict.
  int _lastLoadPending = 0;

  set pqRootLocked(bool v) {
    _pqRootLockedOut = v;
    // The lock is decided after the load, so recompute the verdict here.
    _settingsRestoreUnreadable = v && _lastLoadPending > 0;
  }

  bool get pqRootLoadSucceeded => _pqRootLoadSucceeded;

  bool get pqRootRowPresent => _pqRootRowPresent;

  /// The parsed record, or null when absent or unopened.
  PqRootRecord? get pqRootRecord {
    final raw = _lastInboundPqRoot;
    return raw == null ? null : PqRootRecord.fromJson(raw);
  }

  /// Notes the pq-root row under either the hashed column or the bare routing name.
  void _notePqRootColumns(Map<dynamic, dynamic> cats) {
    _pqRootLoadSucceeded = true;
    _pqRootRowPresent = false;
    _pqRootRowHybrid = false;
    _lastInboundPqRoot = null;
    final hashed = d1Category(pqRootCategory);
    for (final k in cats.keys) {
      final name = k.toString();
      if (name != hashed && name != pqRootCategory) continue;
      final entry = cats[k];
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is String && blob.isNotEmpty) {
        _pqRootRowPresent = true;
        _pqRootRowHybrid = pq.isPqPayload(blob) || pq.isPq2Payload(blob);
        return;
      }
    }
  }

  bool _pqRootRowHybrid = false;

  bool get pqRootRowHybrid => _pqRootRowHybrid;

  bool get pqRootRowUnreadable {
    if (!_pqRootRowPresent) return false;
    final rec = pqRootRecord;
    return rec == null || !rec.isValid;
  }

  /// Publishes the root record, forced classical to avoid a circular lock.
  Future<bool> pqRootRecordSet(PqRootRecord record) async {
    final ok = await _setSettingsCategory(
      d1Category(pqRootCategory),
      jsonEncode(_withCat(record.toJson(), pqRootCategory)),
      allowPq: false,
    );
    if (ok) {
      _lastInboundPqRoot = record.toJson();
      _pqRootRowPresent = true;
      _pqRootRowHybrid = false;
    }
    return ok;
  }

  /// Publishes `nymchat-notifications`, defaulting unowned fields to the last inbound values; no-op when empty or unchanged.
  Future<bool> notificationsWrapSet(
    Map<String, dynamic> seenNotifications, {
    List<dynamic>? notificationHistory,
    int? notificationLastReadTime,
  }) async {
    const dTag = 'nymchat-notifications';
    final inbound = _lastInboundNotifications;
    final history = List<dynamic>.of(notificationHistory ??
        (inbound?['notificationHistory'] is List
            ? inbound!['notificationHistory'] as List
            : const <dynamic>[]));
    final lastRead = notificationLastReadTime ??
        (inbound?['notificationLastReadTime'] as num?)?.toInt() ??
        0;
    if (history.isEmpty && lastRead <= 0 && seenNotifications.isEmpty) {
      return false;
    }
    final payload = <String, dynamic>{
      'notificationHistory': history,
      'notificationLastReadTime': lastRead,
      if (seenNotifications.isNotEmpty)
        'seenNotifications': Map<String, dynamic>.of(seenNotifications),
    };
    // Same hashed-column scheme and wrap path as the settings sections.
    return _publishCategoryWrap(payload, dTag, trim: _trimNotifications);
  }

  /// D1-only `nymchat-readstate` `{channelLastRead}`, keeping the newest 2000 positive entries; no-op when empty or unchanged.
  Future<bool> readStateSet(Map<String, int> channelLastRead) async {
    if (channelLastRead.isEmpty) return false;
    final entries = <MapEntry<String, int>>[
      for (final e in channelLastRead.entries)
        if (e.value > 0) MapEntry(e.key, e.value),
    ];
    if (entries.isEmpty) return false;
    // Keep the most recently read conversations.
    entries.sort((a, b) => b.value.compareTo(a.value));
    const maxEntries = 2000;
    final capped =
        entries.length > maxEntries ? entries.sublist(0, maxEntries) : entries;
    final map = <String, dynamic>{for (final e in capped) e.key: e.value};
    const dTag = 'nymchat-readstate';
    // Bare `{channelLastRead}` as in the PWA; `__cat` keeps the D1 column opaque.
    final payload = <String, dynamic>{'channelLastRead': map};
    return _setSettingsCategory(
      d1Category(dTag),
      jsonEncode(_withCat(payload, dTag)),
    );
  }

  // Per-group sync categories, on the same hashed-column path; applied in [settingsGet].

  /// Per-group d-tag `<prefix>-<lowercased gid>`, for `nymchat-keys` and `nymchat-history`.
  static String _groupSyncDTag(String prefix, String groupId) =>
      '$prefix-${groupId.toLowerCase()}';

  /// Overwrites a left group's `nymchat-keys-<gid>` with `{}` so a fresh device can't restore its keys; history is kept.
  Future<void> clearGroupSyncData(String groupId) async {
    final dTag = _groupSyncDTag('nymchat-keys', groupId);
    await _setSettingsCategory(
      d1Category(dTag),
      jsonEncode(_withCat(<String, dynamic>{}, dTag)),
    );
  }

  /// `YYYYMM` bucket for a unix-seconds timestamp, one month of history per wrap.
  static String _historyBucketId(int tsSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        (tsSeconds < 0 ? 0 : tsSeconds) * 1000,
        isUtc: true);
    final mm = d.month.toString().padLeft(2, '0');
    return '${d.year}$mm';
  }

  Future<bool> savedSyncSet(Map<String, dynamic> saved) async {
    const dTag = ChatToolsKeys.savedDTag;
    final payload = <String, dynamic>{'savedMessages': saved};
    try {
      final changed =
          await _publishCategoryWrap(payload, dTag, trim: trimSavedPayload);
      if (changed) {
        try {
          await publishSettingsChangedPing(const ['saved']);
        } catch (_) {}
        return true;
      }
      return _publishedSectionJson[dTag] ==
          jsonEncode(_mergeUnknownSectionKeys(dTag, payload));
    } catch (_) {
      return false;
    }
  }

  Future<bool> pinnedSyncSet(Map<String, dynamic> pinned) async {
    const dTag = ChatNavKeys.pinnedDTag;
    final payload = <String, dynamic>{'pinnedChats': pinned};
    try {
      final changed =
          await _publishCategoryWrap(payload, dTag, trim: trimPinnedPayload);
      if (changed) {
        try {
          await publishSettingsChangedPing(const ['pinned']);
        } catch (_) {}
        return true;
      }
      return _publishedSectionJson[dTag] ==
          jsonEncode(_mergeUnknownSectionKeys(dTag, payload));
    } catch (_) {
      return false;
    }
  }

  Future<bool> lockedSyncSet(Map<String, dynamic> locked) async {
    const dTag = ChatLockKeys.lockedDTag;
    final payload = <String, dynamic>{'lockedChats': locked};
    try {
      final changed =
          await _publishCategoryWrap(payload, dTag, trim: trimLockedPayload);
      if (changed) {
        try {
          await publishSettingsChangedPing(const ['locked']);
        } catch (_) {}
        return true;
      }
      return _publishedSectionJson[dTag] ==
          jsonEncode(_mergeUnknownSectionKeys(dTag, payload));
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> scheduleAction(
      String action, Map<String, dynamic> body) {
    return _signedWrite(<String, dynamic>{
      ...body,
      'action': action,
      'pubkey': _pubkey,
    });
  }

  Future<void> botAnonSyncSet(Map<String, dynamic> payload) async {
    try {
      await _publishCategoryWrap({'botAnon': payload}, 'nymchat-botanon');
    } catch (_) {
    }
  }

  Future<void> groupSyncSet({
    required Map<String, Map<String, dynamic>> groupConversations,
    required Map<String, Map<String, dynamic>> ephemeralKeysByGroup,
    required Map<String, List<Map<String, dynamic>>> historyByConvKey,
    Set<String> leftGroups = const {},
  }) async {
    // Group ephemeral keys → nymchat-keys-<gid>, one wrap per group.
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
        // Best-effort per group.
      }
    }

    // Left groups get `{}` over their keys blob so a fresh device can't restore them.
    for (final gid in leftGroups) {
      try {
        await clearGroupSyncData(gid);
      } catch (_) {
        // Best-effort.
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

    // History shards: raw JSON may use 0.628 of the rumor ceiling, leaving room for escaping (PQ lowers the ceiling).
    final shardBudget = (_maxRumorBytes * 0.628).floor();
    for (final e in historyByConvKey.entries) {
      final convKey = e.key;
      final msgs = e.value;
      if (msgs.isEmpty) continue;
      try {
        final gid =
            convKey.startsWith('group-') ? convKey.substring(6) : convKey;
        final base = _groupSyncDTag('nymchat-history', gid);
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

  /// Drops ephemeral-key entries for non-members to bound the payload; returns [entry].
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

  /// When oversized: trims the oldest quarter of prev keys, then drops `memberKeyTs`.
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

  /// Halves every group's modLog when the payload is oversized.
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

  /// Last resort: drops the oldest ~10% of a shard when one message is enormous.
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

  /// Embeds the real category as `__cat` so the cleartext D1 column stays opaque.
  Map<String, dynamic> _withCat(Map<String, dynamic> payload, String category) {
    return {...payload, '__cat': category};
  }

  /// In-memory content hashes so unchanged sections skip the write.
  final Map<String, String> _lastSettingsHash = {};

  /// [allowPq] false forces the classical seal; only [pqRootCategory] needs it.
  Future<bool> _setSettingsCategory(String category, String plaintext,
      {bool allowPq = true}) async {
    try {
      // The seal mode is part of the hash basis so a policy flip republishes; never write over rows we could not read.
      if (_settingsRestoreUnreadable) return false;
      final selfKem = allowPq ? await _pqSelfKeyCandidates() : const [];
      final mode = (allowPq && _pqSealToSelf && selfKem.isNotEmpty) ? 'pq' : 'c';
      final hash = _sha256Hex('$_pubkey|$mode|$plaintext');
      final hashKey = '${_pubkey}_$category';
      if (_lastSettingsHash[hashKey] == hash) return false; // unchanged

      final blob = await _encryptToSelf(plaintext, allowPq: allowPq);
      if (blob == null) return false;

      await _signedWrite(<String, dynamic>{
        'action': 'settings-set',
        'pubkey': _pubkey,
        'category': category,
        'blob': blob,
        'contentHash': hash,
      });
      _lastSettingsHash[hashKey] = hash;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Deletes this account's server rows on wipe, signed while the key is still here.
  Future<bool> purgeAccount() async {
    try {
      if (_pubkey.isEmpty) return false;
      final body = <String, dynamic>{
        'action': 'account-purge',
        'app': 'nymchat',
        'pubkey': _pubkey,
      };
      final auth = await _writeAuth('account-purge', body);
      if (auth == null) return false;
      final res = await _api.storageAction(<String, dynamic>{
        ...body,
        'auth': auth,
      });
      return res['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Loads and merges D1 settings (newest wins); null only on a real failure or rows a remote signer couldn't open.
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
    _notePqRootColumns(cats);

    final decoded = <_DecodedCategory>[];
    var storedBlobs = 0;
    var pending = 0; // Rows that did not open.
    for (final e in cats.entries) {
      final entry = e.value;
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      storedBlobs++;
      final updatedAt = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      try {
        final plain = await _decryptFromSelf(blob);
        if (plain == null) {
          pending++;
          continue;
        }
        final payload = jsonDecode(plain);
        if (payload is! Map<String, dynamic>) continue;
        final realCat = payload['__cat'] is String
            ? payload['__cat'] as String
            : e.key.toString();
        payload.remove('__cat');
        // Keep the raw payload for [_mergeUnknownSectionKeys].
        _lastInboundSections[realCat] = Map<String, dynamic>.from(payload);
        if (realCat == pqRootCategory) {
          _lastInboundPqRoot = Map<String, dynamic>.of(payload);
          _pqRootRowPresent = true;
        }
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable or corrupt category.
        pending++;
      }
    }

    // Unopened rows sealed to a root this device lacks are recoverable, so they must block saving.
    _lastLoadPending = pending;
    _settingsRestoreUnreadable = pending > 0 && _pqRootLockedOut;
    if (decoded.isEmpty) {
      // Null means failure and keeps saves off; empty accounts and rows a local nsec can never open still return a result.
      if (storedBlobs == 0) {
        return const SettingsLoadResult(payload: {}, newestTs: 0);
      }
      // Locked out of the root: recoverable by linking, so never final.
      if (_pqRootLockedOut) return null;
      if (_signer is LocalSigner) {
        return const SettingsLoadResult(payload: {}, newestTs: 0);
      }
      return null;
    }

    // Notification read-state wrap, a separate category, for merging seen keys.
    Map<String, dynamic>? notificationsPayload;
    // Non-core `nymchat-readstate`, applied additively regardless of the core ts gate.
    Map<String, dynamic>? readStatePayload;
    // Per-group categories, applied additively regardless of the core ts gate.
    Map<String, dynamic>? groupConversations;
    Map<String, dynamic>? botAnon;
    Map<String, dynamic>? savedMessages;
    Map<String, dynamic>? pinnedChats;
    Map<String, dynamic>? lockedChats;
    final groupEphemeralKeys = <String, dynamic>{};
    final groupMessageHistory = <String, List<dynamic>>{};
    for (final d in decoded) {
      final c = d.category;
      if (c == 'nymchat-notifications') {
        notificationsPayload = d.payload;
        // Copied for carry-forward in [notificationsWrapSet].
        _lastInboundNotifications = Map<String, dynamic>.of(d.payload);
      }
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
          ek.forEach(
              (gid, entry) => groupEphemeralKeys[gid.toString()] = entry);
        }
      } else if (c == ChatToolsKeys.savedDTag) {
        final saved = d.payload['savedMessages'];
        if (saved is Map) savedMessages = saved.cast<String, dynamic>();
      } else if (c == ChatNavKeys.pinnedDTag) {
        final pinned = d.payload['pinnedChats'];
        if (pinned is Map) pinnedChats = pinned.cast<String, dynamic>();
      } else if (c == ChatLockKeys.lockedDTag) {
        final locked = d.payload['lockedChats'];
        if (locked is Map) lockedChats = locked.cast<String, dynamic>();
      } else if (c == 'nymchat-botanon') {
        final anon = d.payload['botAnon'];
        if (anon is Map) botAnon = anon.cast<String, dynamic>();
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

    // Apply section blobs oldest to newest; the legacy monolithic blob only when none exist.
    final core = decoded.where((d) => isCore(d.category)).toList();
    final sections = core
        .where((d) => d.category != 'nymchat-settings')
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final toApply = sections.isNotEmpty
        ? sections
        : core.where((d) => d.category == 'nymchat-settings').toList();
    final hasGroupData = groupConversations != null ||
        groupEphemeralKeys.isNotEmpty ||
        groupMessageHistory.isNotEmpty ||
        botAnon != null ||
        savedMessages != null ||
        pinnedChats != null ||
        lockedChats != null;
    if (toApply.isEmpty) {
      // Non-core payloads alone are still worth returning.
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
              botAnon: botAnon,
              savedMessages: savedMessages,
              pinnedChats: pinnedChats,
              lockedChats: lockedChats,
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
      botAnon: botAnon,
      savedMessages: savedMessages,
      pinnedChats: pinnedChats,
      lockedChats: lockedChats,
    );
  }

  /// Settings sections newer than [sinceMs] as accept/decline offers, newest first; empty on failure.
  Future<List<SettingsTransferOffer>> settingsTransfersSince(
      int sinceMs) async {
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
    _notePqRootColumns(cats);

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
        // Keep the raw payload for [_mergeUnknownSectionKeys].
        _lastInboundSections[realCat] = Map<String, dynamic>.from(payload);
        if (realCat == 'nymchat-notifications') {
          // Cache for carry-forward in [notificationsWrapSet], as [settingsGet] does.
          _lastInboundNotifications = Map<String, dynamic>.of(payload);
        }
        if (realCat == pqRootCategory) {
          _lastInboundPqRoot = Map<String, dynamic>.of(payload);
          _pqRootRowPresent = true;
        }
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable or corrupt category.
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
    // Surface `nymchat-readstate` here too when newer than the last sync.
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

  // D1-first profile mirror

  /// Pubkey to ms cached, so fresh profiles skip the D1 round-trip.
  final Map<String, int> _profileCacheAt = {};
  static const int _profileCacheTtlMs = 5 * 60 * 1000;

  /// Batch-reads kind-0s from D1 (public, 100 per request); cache hits count as found; failures return empty.
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
    final out = <String, Map<String, dynamic>>{};
    // Report cache hits so the caller skips them.
    for (final pk in foundFromCache) {
      out.putIfAbsent(pk, () => const {});
    }
    if (toFetch.isEmpty) return out;

    for (var start = 0; start < toFetch.length; start += 100) {
      final end = start + 100;
      final batch =
          toFetch.sublist(start, end > toFetch.length ? toFetch.length : end);
      StorageStream stream;
      try {
        // profile-get is a public read.
        stream = await _api.storageStream({
          'action': 'profile-get',
          'pubkeys': batch,
        });
      } catch (_) {
        break;
      }
      for (final item in stream.items) {
        // Each line is `[pubkey, rec]`: rec is `{event, updatedAt}` or null.
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
    }
    return out;
  }

  /// Marks [pubkey] freshly cached so no D1 read is issued for it.
  void markProfileCached(String pubkey) {
    _profileCacheAt[pubkey.toLowerCase()] =
        DateTime.now().millisecondsSinceEpoch;
  }

  /// Mirrors our signed kind-0 to D1 (`profile-set`) for fast public reads; best-effort.
  Future<void> profileSet(Map<String, dynamic> signedEvent) async {
    try {
      await _signedWrite({
        'action': 'profile-set',
        'pubkey': _pubkey,
        'event': signedEvent,
      });
      final id = signedEvent['id'];
      if (id is String) markProfileCached(_pubkey);
    } catch (_) {
      // Best-effort mirror.
    }
  }

  // PM gift-wrap archive (durable identities only)

  /// Wrap ids uploaded this session, capped like the PWA (6000, trimmed to 4000).
  final Set<String> _archivedIds = {};
  final Set<String> _depositedIds = {};
  final List<Map<String, dynamic>> _depositQueue = [];
  final Random _depositRandom = Random();
  Timer? _depositTimer;
  int depositDropped = 0;
  int depositFailed = 0;
  final Expando<int> _depositAttempts = Expando<int>();
  int _depositFailStreak = 0;
  DateTime? _depositRetryAt;

  /// Uploads wraps p-tagged to us into our D1 inbox (`pm-put`); no-op for ephemeral identities. Returns the count sent.
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
      await _signedWrite({
        'action': 'pm-put',
        'pubkey': _pubkey,
        'events': batch.take(100).toList(),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
  }

  /// Deposits a wrap into the recipient's D1 inbox (`pm-deposit`); skips self and ephemeral. Returns the count sent.
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
    final sent = batch.take(100).toList();
    try {
      await _signedWrite({
        'action': 'pm-deposit',
        'pubkey': _pubkey,
        'events': sent,
      });
      _depositFailStreak = 0;
      return batch.length;
    } catch (e) {
      _requeueDeposits(sent, e);
      _armDepositRetry();
      return 0;
    }
  }

  void enqueueDeposit(Map<String, dynamic> wrap) {
    if (!_durable) return;
    final id = wrap['id'];
    if (id is! String || id.isEmpty) return;
    final recipient = _recipientOf(wrap);
    if (recipient == null || recipient == _pubkey) return;
    if (_depositedIds.contains(id)) return;
    _depositedIds.add(id);
    _trim(_depositedIds);
    _depositQueue.add(wrap);
    while (_depositQueue.length > kPmDepositQueueMax) {
      _depositQueue.removeAt(_depositRandom.nextInt(_depositQueue.length));
      depositDropped++;
    }
    _depositTimer ??= Timer(_depositDelay(false), () => _flushDeposits());
  }

  Duration _depositDelay(bool backlog) => Duration(
      milliseconds: (backlog ? kPmDepositBacklogMs : kPmDepositFlushMs) +
          _depositRandom.nextInt(kPmDepositFlushJitterMs + 1));

  int _depositBatchSize() =>
      kPmDepositBatchMin +
      _depositRandom.nextInt(kPmDepositBatchMax - kPmDepositBatchMin + 1);

  Duration _depositRetryWait() {
    final at = _depositRetryAt;
    if (at == null) return Duration.zero;
    final wait = at.difference(_now());
    return wait.isNegative ? Duration.zero : wait;
  }

  bool _depositRetryable(Object err) {
    if (err is! ApiException) return true;
    final status = err.statusCode;
    if (status == 0) return true;
    return status == 408 || status == 429 || status >= 500;
  }

  Duration _depositRetryDelay(Object err, int streak) {
    final exp = streak < 1 ? 0 : (streak > 17 ? 16 : streak - 1);
    final backoff = min(kPmDepositRetryMaxMs, kPmDepositRetryBaseMs << exp);
    final told = err is ApiException ? err.retryAfter : null;
    final toldMs =
        told == null ? 0 : min(kPmDepositRetryMaxMs, told.inMilliseconds);
    return Duration(
        milliseconds: max(backoff, toldMs) +
            _depositRandom.nextInt(kPmDepositRetryBaseMs ~/ 2 + 1));
  }

  void _requeueDeposits(List<Map<String, dynamic>> batch, Object err) {
    final retryable = _depositRetryable(err);
    final keep = <Map<String, dynamic>>[];
    for (final ev in batch) {
      final n = (_depositAttempts[ev] ?? 1) + 1;
      if (retryable && n <= kPmDepositMaxAttempts) {
        _depositAttempts[ev] = n;
        keep.add(ev);
      }
    }
    depositFailed += batch.length - keep.length;
    if (keep.isEmpty) return;
    _depositFailStreak++;
    _depositRetryAt = _now().add(_depositRetryDelay(err, _depositFailStreak));
    _depositQueue.insertAll(0, keep);
    while (_depositQueue.length > kPmDepositQueueMax) {
      _depositQueue.removeAt(_depositRandom.nextInt(_depositQueue.length));
      depositDropped++;
    }
  }

  void _armDepositRetry() {
    if (_depositQueue.isEmpty) return;
    final backlog = _depositDelay(true);
    final wait = _depositRetryWait();
    _depositTimer ??=
        Timer(wait > backlog ? wait : backlog, () => _flushDeposits());
  }

  Future<void> _flushDeposits({bool rearm = true}) async {
    _depositTimer = null;
    if (_depositQueue.isEmpty) return;
    if (_depositRetryWait() > Duration.zero) {
      if (rearm) _armDepositRetry();
      return;
    }
    _depositQueue.shuffle(_depositRandom);
    final size = _depositBatchSize();
    final n = size < _depositQueue.length ? size : _depositQueue.length;
    final batch = _depositQueue.sublist(0, n);
    _depositQueue.removeRange(0, n);
    try {
      await _signedWrite({
        'action': 'pm-deposit',
        'pubkey': _pubkey,
        'events': batch,
      });
      _depositFailStreak = 0;
    } catch (e) {
      _requeueDeposits(batch, e);
    }
    if (rearm) _armDepositRetry();
  }

  Future<void> flushDeposits() async {
    _depositTimer?.cancel();
    _depositTimer = null;
    while (_depositQueue.isNotEmpty && _depositRetryWait() == Duration.zero) {
      await _flushDeposits(rearm: false);
    }
    _armDepositRetry();
  }

  /// Deletes wraps from our D1 inbox in 200-id chunks; returns rows removed; no-op for ephemeral identities.
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
        final res = await _signedWrite({
          'action': 'pm-delete',
          'pubkey': _pubkey,
          'ids': clean.sublist(i, end),
        });
        removed += (res['removed'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // Best-effort purge.
      }
    }
    return removed;
  }

  /// Oldest restored wrap ts and an end-of-history flag for the pager.
  int? _pmOldestTs;
  bool _pmNoMore = false;

  /// Restores a page of archived wraps (oldest to newest, deduped) and advances the pager; empty for ephemeral identities.
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
    // End of history when the worker says so or the page was short.
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

  /// Restores up to 5 pages of 200 at boot and resets the pager.
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

  /// Loads the next older page; empty when there is no more history.
  bool get pmArchiveHasOlder => !_pmNoMore && _pmOldestTs != null;

  Future<List<Map<String, dynamic>>> pmLoadOlderFromD1() async {
    if (_pmNoMore || _pmOldestTs == null) return const [];
    return pmGet(before: _pmOldestTs!, limit: 200);
  }

  /// Restores group history deposited under our per-group ephemeral keys; public, no `since`, 200-pubkey chunks.
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
        // Public read: no pubkey/auth.
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

  // Channel archive (D1 `channel-get`)

  /// Per-channel last-fetched ms, throttling re-fetches.
  final Map<String, int> _channelFetchedAt = {};

  /// Restores channel history for up to 50 channels, skipping ones fetched in the last 60s unless [force]; public.
  Future<List<Map<String, dynamic>>> channelGet(
    List<String> channelNames, {
    bool force = false,
    int sinceSec = 0,
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
      // channel-get is a public read.
      stream = await _api.storageStream({
        'action': 'channel-get',
        'channels': names,
        if (sinceSec > 0) 'since': sinceSec,
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

  /// One author's rows from an archived channel, unthrottled; callers must verify signatures since D1 is only a cache.
  Future<List<Map<String, dynamic>>> channelGetByAuthor(
    String channel,
    String author,
  ) async {
    if (channel.isEmpty || author.isEmpty) return const [];
    StorageStream stream;
    try {
      stream = await _api.storageStream({
        'action': 'channel-get',
        'channel': channel,
        'authors': [author],
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

  Future<Map<String, dynamic>?> pqKey(String pubkey) async {
    final res = await _api.botAction({'action': 'pq-key', 'pubkey': pubkey});
    if (!res.containsKey('event')) {
      throw ApiException('pq-key', 200, 'missing event');
    }
    final ev = res['event'];
    return ev is Map ? Map<String, dynamic>.from(ev) : null;
  }

  /// Purges a NIP-09-deleted message; public, since the signed kind-5 is the authorization. [channel] has no `#`.
  Future<void> channelDelete(
    String channel,
    Map<String, dynamic> deletionEvent,
  ) async {
    if (channel.isEmpty) return;
    try {
      // Public: no pubkey/auth.
      await _api.storageAction({
        'action': 'channel-delete',
        'channel': channel,
        'deletionEvent': deletionEvent,
      });
    } catch (_) {
      // Best-effort purge.
    }
  }

  // Channel activity discovery (public D1 reads)

  /// Channel activity shape: name to 24 hourly buckets (0 = current hour) plus last-activity seconds.
  final Map<String, List<int>> _emptyActivity = const {};

  /// Recently active geohash channels from D1 (public); empty maps on failure.
  Future<ChannelActivityResult> channelActive() =>
      _channelDiscover('channel-active');

  /// Recently active named channels from D1 (public).
  Future<ChannelActivityResult> channelActiveNamed() =>
      _channelDiscover('channel-active-named');

  Future<ChannelActivityResult> _channelDiscover(String action) async {
    Map<String, dynamic> data;
    try {
      // Public read: no pubkey/auth.
      data = await _api.storageAction({'action': action});
    } catch (_) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Last `channel-activity` fetch in ms, for the 30s throttle.
  int _activityFetchedAt = 0;

  /// Batched activity counts for up to 200 names, throttled to 30s unless [force]; public; empty on failure.
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
      if (names.length >= 200) break; // Server caps at 200.
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
      _activityFetchedAt = 0; // Allow a retry on transport failure.
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Parses a channel-activity response, lowercasing names and tolerating malformed fields.
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
        if (ts is num && ts > 0) {
          last[name.toString().toLowerCase()] = ts.toInt();
        }
      });
    }
    return ChannelActivityResult(activity: activity, last: last);
  }

  // Custom-emoji archive (D1 `emoji-get`)

  /// Last `emoji-get` fetch in ms; refetched at most every 10 minutes.
  int _emojiFetchedAt = 0;

  /// Archived NIP-30 packs and our 10030 list from D1, throttled to 10 minutes; empty on failure.
  Future<List<Map<String, dynamic>>> emojiGet({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _emojiFetchedAt != 0 && now - _emojiFetchedAt < 600000) {
      return const [];
    }
    _emojiFetchedAt = now;
    StorageStream stream;
    try {
      // Empty body so the HTTP fallback stays anonymous; the authed socket adds our 10030 server-side.
      stream = await _api.storageStream({
        'action': 'emoji-get',
      });
    } catch (_) {
      _emojiFetchedAt = 0; // Allow a retry.
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      events.add(Map<String, dynamic>.from(item));
    }
    return events;
  }

  // Zap-receipt archive (D1 `zap-put` / `zap-get`)

  /// Uploads validated kind-9735 receipts (authed, ≤100 per call); best-effort.
  Future<bool> zapPut(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return false;
    try {
      await _signedWrite({
        'action': 'zap-put',
        'pubkey': _pubkey,
        'events': events.take(100).toList(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Archived receipts for up to 500 [ids] in [scope] 'pm' or 'channel' (profiles use pubkey ids); public.
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
      if (clean.length >= 500) break; // Server caps at 500.
    }
    if (clean.isEmpty) return const [];
    StorageStream stream;
    try {
      // Public read: no pubkey/auth.
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

  // Other users' active shop items (D1 `shop-status`)

  /// Batch-reads up to 100 users' active shop items (public); [fresh] bypasses the server cache; empty on failure.
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
      if (pks.length >= 100) break; // Server caps at 100.
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

  // Helpers

  /// Signs a kind-27235 auth for [action] via the injected builder; null when there is none or signing fails.
  Future<Map<String, dynamic>?> _auth(String action) async =>
      _authBuilder == null ? null : await _authBuilder!(action);

  Future<Map<String, dynamic>?> _writeAuth(
      String action, Map<String, dynamic> body) async {
    final builder = _writeAuthBuilder;
    if (builder == null) return _auth(action);
    return builder(action, Nip98Auth.payloadHashHex(body));
  }

  Future<Map<String, dynamic>> _signedWrite(Map<String, dynamic> body) async {
    final action = body['action'] as String;
    final unsigned = Map<String, dynamic>.of(body)..remove('auth');
    final signed = <String, dynamic>{
      ...unsigned,
      'auth': await _writeAuth(action, unsigned),
    };
    return _api.storageAction(signed);
  }

  Future<Map<String, dynamic>?> Function(String action, String payload)?
      _writeAuthBuilder;

  void setWriteAuthBuilder(
    Future<Map<String, dynamic>?> Function(String action, String payload)
        builder,
  ) {
    _writeAuthBuilder = builder;
  }

  /// Injected auth builder returning a signed kind-27235 event or null; when unset, callers pass `auth` themselves.
  Future<Map<String, dynamic>?> Function(String action)? _authBuilder;

  /// Registers the auth builder, signing via the active local or NIP-46 signer.
  void setAuthBuilder(
    Future<Map<String, dynamic>?> Function(String action) builder,
  ) {
    _authBuilder = builder;
  }

  /// Our ML-KEM keypairs, current epoch first; empty until post-quantum is up or for logins that can't.
  List<({Uint8List kemSk, Uint8List kemPk})> _pqSelfKeys = const [];

  void setPqSelfKeys(List<({Uint8List kemSk, Uint8List kemPk})> keys) {
    _pqSelfKeys = List.unmodifiable(keys);
  }

  /// ML-KEM keypairs to try, derived when none were handed over, so the boot read never misses them; root-derived first.
  Future<List<({Uint8List kemSk, Uint8List kemPk})>>
      _pqSelfKeyCandidates() async {
    final root = await _pqRoot();
    if (_pqSelfKeys.isNotEmpty) return _pqSelfKeys;
    final signer = _signer;
    final cached = _derivedPqSelfKeys;
    if (cached != null) return cached;
    final epoch = _pqEpochProvider?.call() ?? 0;
    try {
      if (signer is! LocalSigner) {
        if (root == null) return const [];
        return _derivedPqSelfKeys = pqRootCandidates(root, epoch);
      }
      return _derivedPqSelfKeys =
          pqSelfCandidates(signer.privkey, epoch, root: root);
    } catch (_) {
      return const [];
    }
  }

  int Function()? _pqEpochProvider;

  void setPqEpochProvider(int Function() provider) {
    _pqEpochProvider = provider;
    _derivedPqSelfKeys = null;
  }

  /// Reads the root secret once per instance; null means nsec-derived candidates only (v1).
  Future<Uint8List?> Function()? _pqRootProvider;
  Future<Uint8List?>? _pqRootFuture;

  /// A provider rather than a setter, so the root is available to the boot settings read.
  void setPqRootProvider(Future<Uint8List?> Function() provider) {
    _pqRootProvider = provider;
    _pqRootFuture = null;
    _derivedPqSelfKeys = null;
  }

  Future<Uint8List?> _pqRoot() {
    final provider = _pqRootProvider;
    if (provider == null) return Future.value(null);
    return _pqRootFuture ??= provider().catchError((_) => null);
  }

  /// Cache for [_pqSelfKeyCandidates], since ML-KEM keygen is not free.
  List<({Uint8List kemSk, Uint8List kemPk})>? _derivedPqSelfKeys;

  /// Whether new self blobs may be sealed hybrid (all devices capable); gates writes only and defaults false.
  bool _pqSealToSelf = false;

  void setPqSealToSelf(bool enabled) {
    _pqSealToSelf = enabled;
  }

  /// Seals a self blob hybrid when this device has a root and every device can open it; [allowPq] false forces classical.
  Future<String?> _encryptToSelf(String plaintext,
      {bool allowPq = true}) async {
    try {
      final signer = _signer;
      final candidates = allowPq
          ? await _pqSelfKeyCandidates()
          : const <({Uint8List kemSk, Uint8List kemPk})>[];
      final selfKem = candidates.isEmpty ? null : candidates.first;
      // Local key: run the whole seal off the main isolate; failures fall through to the inline path.
      if (signer is LocalSigner) {
        try {
          final job = <String, dynamic>{
            'sk': keys.bytesToHex(signer.privkey),
            'self': _pubkey,
            'plaintext': plaintext,
            if (allowPq && _pqSealToSelf && selfKem != null)
              'kemPk': selfKem.kemPk,
          };
          final blob = kIsWeb
              ? await encryptToSelfIsolate(job)
              : await compute(encryptToSelfIsolate, job);
          if (blob != null) return blob;
        } catch (_) {
          // Inline below.
        }
      }
      if (allowPq && _pqSealToSelf && selfKem != null) {
        try {
          // Layered: the outer layer is keyed from the KEM secret alone, so the inner NIP-44 can come from a signer.
          final inner = await signer.nip44Encrypt(_pubkey, plaintext);
          return await pq.pq2Seal(inner, _pubkey, _pubkey, selfKem.kemPk);
        } catch (_) {
          // Fall through to NIP-44 rather than losing the write.
        }
      }
      return await signer.nip44Encrypt(_pubkey, plaintext);
    } catch (_) {
      return null;
    }
  }

  /// Forgets content hashes so post-link writes aren't skipped as unchanged.
  void clearSettingsHashes() => _lastSettingsHash.clear();

  /// Reads NIP-44, `pq1.` or `pq2.` blobs, trying every derivable epoch.
  Future<String?> _decryptFromSelf(String ciphertext) async {
    try {
      final signer = _signer;
      // Layered first: both apps write it, and a signer can open the inner layer.
      if (pq.isPq2Payload(ciphertext)) {
        for (final k in await _pqSelfKeyCandidates()) {
          try {
            final inner = await pq.pq2Open(
                ciphertext, _pubkey, _pubkey, k.kemSk, k.kemPk);
            return await signer.nip44Decrypt(_pubkey, inner);
          } catch (_) {
            // Wrong epoch: try the next.
          }
        }
        return null;
      }
      // The combined form: only a local nsec can open it.
      if (pq.isPqPayload(ciphertext)) {
        if (signer is! LocalSigner) return null;
        for (final k in await _pqSelfKeyCandidates()) {
          try {
            return pq.pqDecrypt(
              ciphertext,
              _pubkey,
              pq.PqIdentity(
                privkey: signer.privkey,
                kemSecretKey: k.kemSk,
                kemPublicKey: k.kemPk,
              ),
            );
          } catch (_) {
            // Wrong epoch: try the next.
          }
        }
        return null;
      }
      return await signer.nip44Decrypt(_pubkey, ciphertext);
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

  /// The storage endpoint URL the NIP-98 `u` tag must bind to.
  static String storageUrl() => 'https://${ApiConfig.apiHost}/api/storage';
}

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

/// Merged settings payload and newest core `updatedAt` (ms); apply only when newer than the stored sync ts.
class SettingsLoadResult {
  const SettingsLoadResult({
    required this.payload,
    required this.newestTs,
    this.notificationsPayload,
    this.readStatePayload,
    this.groupConversations,
    this.groupEphemeralKeys = const {},
    this.groupMessageHistory = const {},
    this.botAnon,
    this.savedMessages,
    this.pinnedChats,
    this.lockedChats,
  });
  final Map<String, dynamic> payload;
  final int newestTs;

  /// Decoded `nymchat-groups` (group id to serialized group), applied additively; null when absent.
  final Map<String, dynamic>? groupConversations;

  /// Merged `nymchat-keys-<gid>` rows: group id to ephemeral-key entry.
  final Map<String, dynamic> groupEphemeralKeys;

  /// Concatenated `nymchat-history` shards: `group-<gid>` to message maps.
  final Map<String, List<dynamic>> groupMessageHistory;

  final Map<String, dynamic>? botAnon;

  final Map<String, dynamic>? savedMessages;

  final Map<String, dynamic>? pinnedChats;

  final Map<String, dynamic>? lockedChats;

  /// Decrypted `nymchat-notifications` payload, merged additively regardless of the ts gate.
  final Map<String, dynamic>? notificationsPayload;

  /// Decrypted `nymchat-readstate` payload, applied additively regardless of the core ts gate.
  final Map<String, dynamic>? readStatePayload;
}

/// One newer synced settings section from another device, shown as an accept/decline row.
class SettingsTransferOffer {
  const SettingsTransferOffer({
    required this.id,
    required this.section,
    required this.payload,
    required this.updatedAt,
  });

  /// Stable id (the D1 category), used as the accept/decline key.
  final String id;

  /// Settings section name, or the raw category for the legacy blob.
  final String section;

  /// The decoded payload (PWA field names, `__cat` removed).
  final Map<String, dynamic> payload;

  /// The category's `updatedAt` in ms (publishing device's clock).
  final int updatedAt;
}

/// Channel-activity result: lowercased name to 24 hourly buckets (0 = current hour) and last-activity seconds.
class ChannelActivityResult {
  const ChannelActivityResult({required this.activity, required this.last});

  /// Channel name to 24 hourly message-count buckets.
  final Map<String, List<int>> activity;

  /// Channel name to last-activity unix seconds.
  final Map<String, int> last;

  bool get isEmpty => activity.isEmpty && last.isEmpty;
}

/// Another user's active shop items and `updatedAt`, used to skip unchanged re-renders.
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

/// `shop-status` active block: `{style, flair, cosmetics, supporter, editions}`.
class ShopStatusActive {
  const ShopStatusActive({
    this.style,
    this.flair = const [],
    this.cosmetics = const [],
    this.supporter = false,
    this.editions = const {},
  });

  final String? style;

  /// Active nickname-flair ids; the last is rendered.
  final List<String> flair;

  final List<String> cosmetics;

  final bool supporter;

  /// Item id to edition number.
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

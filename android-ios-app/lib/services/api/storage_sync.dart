import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../../models/settings.dart';
import '../nostr/event_signer.dart';
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
  })  : _api = api,
        _signer = signer,
        _pubkey = pubkey.toLowerCase(),
        _durable = durableIdentity;

  final ApiClient _api;
  final EventSigner _signer;
  final String _pubkey;

  /// True for a logged-in (nsec/nip46/extension) identity — `isNostrLoggedIn()`
  /// in the PWA (`loginMethod != null`). Ephemeral identities skip the durable
  /// PM archive entirely (pms.js `_pmArchiveAllowed`).
  final bool _durable;

  bool get durableIdentity => _durable;

  // ===========================================================================
  // Settings categories that sync vs stay device-local.
  // ===========================================================================

  /// The settings-modal section -> core-key map the PWA splits the synced
  /// payload into (`NYM_SETTINGS_SECTION_KEYS`, settings.js:8). Each section is
  /// published as its own encrypted category `nymchat-settings-<section>` so a
  /// single change is a small write. Keys NOT in any list fall into `misc`.
  ///
  /// Only the keys the native [Settings] model actually carries are listed here
  /// (the PWA syncs many more localStorage-backed prefs; the native model is a
  /// subset). Each value is the JSON key written into the blob, matching the
  /// PWA payload field name (`_buildSettingsPayload`).
  static const Map<String, List<String>> syncedSectionKeys = {
    'appearance': [
      'theme',
      'sound',
      'autoscroll',
      'showTimestamps',
      'timeFormat',
      'dateFormat',
      'chatLayout',
      'chatViewMode',
      'columnsLayout', // carried for parity; native columns layout is empty
      'columnsWallpaper',
      'nickStyle',
      'colorMode',
      'wallpaperType',
      'textSize',
      'transparencyEnabled',
    ],
    'privacy': [
      'dmForwardSecrecyEnabled',
      'dmTTLSeconds',
      'readReceiptsEnabled',
      'readReceiptsScope',
      'typingIndicatorsEnabled',
      'typingIndicatorsScope',
      'acceptPMs',
      'acceptCalls',
      'showStatus',
    ],
    'messaging': [
      'groupChatPMOnlyMode',
      'translateLanguage',
      'gesturesEnabled',
      'swipeLeftAction',
      'swipeRightAction',
      'swipeThreshold',
      'swipeReactEmoji',
      'notificationsEnabled',
      'syncMLSHistory',
    ],
    'channels': [
      'sortByProximity',
    ],
    'data': [
      'lowDataMode',
      'cachePMs',
    ],
  };

  /// Settings that stay DEVICE-LOCAL and are never published (verified against
  /// settings.js): the keypair mode and identity factors (`keypairMode`,
  /// `encryptAtRestPreferred` are sync'd by the PWA but are device-setup hints,
  /// and the native model doesn't expose them), the at-rest vault, and
  /// `textSize` is treated by the native model as appearance — but `blurImages`
  /// (image blur) and `powDifficulty` are stored purely in KV and not part of
  /// the typed [Settings] sync surface here. Exposed for tests/documentation.
  ///
  /// NOTE: the PWA *does* sync `textSize`; we include it under `appearance`
  /// above for parity. The genuinely-local set below is what we deliberately
  /// exclude from the sync blob.
  static const Set<String> deviceLocalKeys = {
    'keypairMode', // identity behavior, set per-device
    'powDifficulty', // KV-only, not in typed Settings sync surface
    'blurImages', // image-blur, KV-only (nym_blur_others_images)
    'hideNonPinned', // KV-only sidebar pref
    'encryptAtRestPreferred', // per-device at-rest factor hint
    'vault', // keypair/secret material never leaves the device
  };

  /// The category name for a section, matching the PWA's d-tag form
  /// `nymchat-settings-<section>` (settings.js:566). The PWA further hashes this
  /// into an opaque per-account D1 column (`_d1Category`) and rides the real
  /// name inside the encrypted blob as `__cat`; we keep the same blob shape but
  /// use the cleartext category as the column (the worker accepts any
  /// `nymchat-[a-z0-9-]{1,120}` category, storage.js:493) so a fresh native
  /// install and the PWA can both read each other's rows.
  // TODO(verify): the PWA uses the *hashed* opaque category as the D1 column
  // (`_d1Category` = `nymchat-<sha256(pubkey:d1:dTag)>`). Using the cleartext
  // category here is simpler and still valid per the worker regex, but does NOT
  // byte-match the PWA's column name, so PWA<->native settings rows won't
  // cross-read until the hashed-category scheme is mirrored. Settings still sync
  // across native devices. Confirm whether cross-client read is required.
  static String sectionCategory(String section) => 'nymchat-settings-$section';

  // ===========================================================================
  // Encrypted settings sync.
  // ===========================================================================

  /// Builds the per-section settings payloads from a [Settings] snapshot,
  /// matching the PWA field names (`_buildSettingsPayload` +
  /// `_splitSettingsBySection`). Each section carries `v: 2` like the PWA.
  /// Returns `{ '<section>': { ...fields } }`.
  static Map<String, Map<String, dynamic>> buildSectionPayloads(Settings s) {
    // The flat synced payload (PWA `_buildSettingsPayload`, subset the native
    // model owns). Booleans/strings/ints map 1:1 to the PWA field names.
    final flat = <String, dynamic>{
      'theme': s.theme.id,
      'sound': s.sound,
      'autoscroll': s.autoscroll,
      'showTimestamps': s.showTimestamps,
      'timeFormat': s.timeFormat,
      'dateFormat': s.dateFormat,
      'chatLayout': s.chatLayout,
      'chatViewMode': s.chatViewMode,
      'columnsLayout': const <dynamic>[],
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
      'lowDataMode': s.lowDataMode,
      'cachePMs': s.cachePMs,
    };

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

  /// Publishes the synced settings sections to D1. For each section it encrypts
  /// the blob (NIP-44 to self) with the real category embedded as `__cat`,
  /// computes the `contentHash` (sha256 of `pubkey|blob-plaintext`) the worker
  /// uses to no-op unchanged writes, and POSTs `settings-set`.
  ///
  /// Returns the set of section names that were sent (changed since last call).
  /// All failures are swallowed; an unchanged section (same content hash) is
  /// skipped without a network call. Mirrors `_saveSettingsBlobToD1`.
  Future<Set<String>> settingsSet(Settings settings) async {
    final sent = <String>{};
    final sections = buildSectionPayloads(settings);
    for (final entry in sections.entries) {
      final category = sectionCategory(entry.key);
      final ok = await _setSettingsCategory(category, jsonEncode(_withCat(
        entry.value,
        category,
      )));
      if (ok) sent.add(entry.key);
    }
    return sent;
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
        'auth': _auth('settings-set'),
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
        'auth': _auth('settings-get'),
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
    if (toApply.isEmpty) return null;

    final merged = <String, dynamic>{};
    var newestTs = 0;
    for (final d in toApply) {
      merged.addAll(d.payload);
      if (d.updatedAt > newestTs) newestTs = d.updatedAt;
    }
    return SettingsLoadResult(payload: merged, newestTs: newestTs);
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
        'auth': _auth('profile-set'),
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
        'auth': _auth('pm-put'),
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
        'auth': _auth('pm-deposit'),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
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
        'auth': _auth('pm-get'),
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

  // ===========================================================================
  // Helpers.
  // ===========================================================================

  /// The NIP-98 (kind-27235) auth event the worker's `verifyClientAuth`
  /// expects, bound to the storage endpoint + action (built via [Nip98Auth] in
  /// the ApiClient; the PWA signs the same event in `_signBotAuth`). Returns the
  /// signed event JSON for `body.auth`.
  ///
  /// The signer abstracts local vs NIP-46 signing; [Nip98Auth.build] takes a
  /// raw privkey, so for the durable-local path we sign through the signer
  /// directly to stay uniform. We build the unsigned event here and sign it.
  Map<String, dynamic>? _auth(String action) => _authBuilder?.call(action);

  /// Auth-event builder injected by the controller (which holds the signer and
  /// can sign sync or async). Returns the signed kind-27235 event JSON. When
  /// null (e.g. pure tests of body shape via a pre-signed auth), callers pass
  /// `auth` themselves. Set via [setAuthBuilder].
  Map<String, dynamic>? Function(String action)? _authBuilder;

  /// Registers the synchronous auth builder. The controller wires this to a
  /// locally-signed kind-27235 event (the common nsec path). For NIP-46 the
  /// builder may return null (auth then omitted; the worker rejects, which is
  /// tolerated — durable NIP-46 settings/PM sync is best-effort).
  void setAuthBuilder(Map<String, dynamic>? Function(String action) builder) {
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
  const SettingsLoadResult({required this.payload, required this.newestTs});
  final Map<String, dynamic> payload;
  final int newestTs;
}

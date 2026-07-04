import 'dart:convert';

import '../../core/constants/storage_keys.dart';
import '../../models/channel.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/app_state.dart';

/// Helpers backing the Settings modal's data-completeness features (gap report
/// 06): the geohash-location label, the landing-channel autocomplete model, the
/// on-device cache-size readout, and the settings-reset key wipe. Kept in the
/// settings slice (no cross-file edits) and side-effect-free where possible so
/// they can be unit-tested.

/// `"37.77°N, 122.41°W"` for a geohash — the PWA's `getGeohashLocation`
/// (geohash-globe.js:1256): decode → abs(lat)°N/S, abs(lng)°E/W. Empty on a
/// decode failure.
String geohashLocationLabel(String geohash) {
  if (geohash.isEmpty || !isValidGeohash(geohash)) return '';
  try {
    final c = decodeGeohash(geohash);
    final latStr =
        '${c.lat.abs().toStringAsFixed(2)}°${c.lat >= 0 ? 'N' : 'S'}';
    final lngStr =
        '${c.lng.abs().toStringAsFixed(2)}°${c.lng >= 0 ? 'E' : 'W'}';
    return '$latStr, $lngStr';
  } catch (_) {
    return '';
  }
}

/// A pinned-landing-channel choice. The PWA persists this as JSON under
/// `nym_pinned_landing_channel`, e.g. `{"type":"geohash","geohash":"nymchat"}`
/// (app.js:3899-3914). Only the `geohash` type is offered by the dropdown.
class LandingChannel {
  const LandingChannel({this.type = 'geohash', required this.geohash});

  final String type;
  final String geohash;

  /// The PWA default (`{type:'geohash', geohash:'nymchat'}`).
  static const LandingChannel defaultChannel =
      LandingChannel(geohash: 'nymchat');

  String toJsonString() => jsonEncode({'type': type, 'geohash': geohash});

  /// `#<geohash>` or `#<geohash> (location)` — the dropdown label form.
  String get label {
    final loc = geohashLocationLabel(geohash);
    return loc.isEmpty ? '#$geohash' : '#$geohash ($loc)';
  }

  static LandingChannel? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['geohash'] is String) {
        return LandingChannel(
          type: (m['type'] as String?) ?? 'geohash',
          geohash: m['geohash'] as String,
        );
      }
    } catch (_) {}
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LandingChannel &&
      other.type == type &&
      other.geohash == geohash;

  @override
  int get hashCode => Object.hash(type, geohash);
}

/// One option in the landing-channel autocomplete, with its group header.
class LandingChannelOption {
  const LandingChannelOption({
    required this.group,
    required this.value,
  });

  /// `'Common Geohash Channels'` or `'Joined Geohash Channels'`.
  final String group;
  final LandingChannel value;

  String get label => value.label;

  /// `"<geohash> <location>"` lowercased — what the type-to-filter matches.
  String get searchText =>
      ('${value.geohash} ${geohashLocationLabel(value.geohash)}')
          .trim()
          .toLowerCase();
}

/// Reads the persisted landing channel (default `nymchat`).
LandingChannel readLandingChannel(KeyValueStore kv) {
  return LandingChannel.tryParse(
          kv.getString(StorageKeys.pinnedLandingChannel)) ??
      LandingChannel.defaultChannel;
}

/// Persists [channel] under `nym_pinned_landing_channel` (PWA saveSettings).
void writeLandingChannel(KeyValueStore kv, LandingChannel channel) {
  kv.setString(StorageKeys.pinnedLandingChannel, channel.toJsonString());
}

/// Builds the grouped landing-channel options exactly like app.js:3350-3389:
/// the 10 common geohashes first, then any joined geohash channels not already
/// listed.
List<LandingChannelOption> buildLandingChannelOptions(
  List<ChannelEntry> channels, {
  List<String> commonGeohashes = const [
    'nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5',
  ],
}) {
  final out = <LandingChannelOption>[];
  final seen = <String>{};
  for (final g in commonGeohashes) {
    if (!seen.add(g)) continue;
    out.add(LandingChannelOption(
      group: 'Common Geohash Channels',
      value: LandingChannel(geohash: g),
    ));
  }
  // Joined geohash channels not already in the common list. `nymchat` is named
  // (never a geohash) so it never double-counts here.
  for (final c in channels) {
    final key = c.key;
    if (!isValidGeohash(key)) continue;
    if (commonGeohashes.contains(key)) continue;
    if (!seen.add(key)) continue;
    out.add(LandingChannelOption(
      group: 'Joined Geohash Channels',
      value: LandingChannel(geohash: key),
    ));
  }
  return out;
}

/// The five valid read-receipt/typing-indicator scopes (settings.js:3
/// `INDICATOR_SCOPES`).
const List<String> kIndicatorScopes = [
  'disabled', 'pms', 'groups', 'pms-groups', 'everywhere',
];

/// Coerces a stored indicator-scope value to a valid scope, mirroring
/// `_normalizeIndicatorScope` (settings.js:27-32): the legacy boolean strings
/// `'true'` → `'everywhere'` and `'false'` → `'disabled'`; any other value not
/// in [kIndicatorScopes] falls back to [fallback].
String normalizeIndicatorScope(String? value,
    {String fallback = 'pms-groups'}) {
  if (value == 'true') return 'everywhere';
  if (value == 'false') return 'disabled';
  if (value != null && kIndicatorScopes.contains(value)) return value;
  return fallback;
}

/// Validates a settings-transfer recipient pubkey, mirroring shop.js:1767:
/// must be exactly 64 hex chars, and not the user's own pubkey. Returns the
/// matching PWA error string, or null when valid.
String? validateTransferPubkey(String input, {required String selfPubkey}) {
  final pk = input.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pk)) {
    return 'Invalid pubkey. Must be 64 hex characters.';
  }
  if (selfPubkey.isNotEmpty && pk == selfPubkey.toLowerCase()) {
    return 'Cannot transfer settings to yourself.';
  }
  return null;
}

/// The on-device cache-size readout shown in Data & Backup (app.js:3681
/// `refreshAppCacheSize`). Native ports compute the item breakdown from the
/// live in-memory store (channels / PM+group threads / profiles / reaction
/// records) with a byte estimate of that content. [realBytes], when > 0, is
/// preferred over the content estimate — the PWA prefers the real
/// `navigator.storage.estimate()` usage over its per-record estimate
/// (app.js:3699 `estimateUsage > 0 ? estimateUsage : counts.totalBytes`); the
/// native analogue is the on-disk `CacheStore.totalBytes()` reading.
///
/// Returns the same human strings:
///  * `"{size} cached on device — N channels, N PM/group threads, N profiles,
///    N reaction records"` (size auto-scaled B/KB/MB/GB)
///  * `"No cached data on device yet"` when nothing is cached.
String cacheReadoutFor(AppState s, {int realBytes = 0}) {
  var channels = 0;
  var pms = 0;
  var bytes = 0;
  s.messages.forEach((key, list) {
    if (list.isEmpty) return;
    // PM (`pm-`) and group (`group-`) threads vs channel (`#`) keys.
    if (key.startsWith('pm-') || key.startsWith('group-')) {
      pms++;
    } else {
      channels++;
    }
    for (final m in list) {
      bytes += m.content.length + m.author.length + 32;
    }
  });
  final profiles = s.users.values.where((u) => u.profile != null).length;
  bytes += profiles * 64;
  final reactions = s.reactions.length;
  bytes += reactions * 48;

  final sizeBytes = realBytes > 0 ? realBytes : bytes;
  final totalItems = channels + pms + profiles + reactions;
  // The PWA's empty state requires BOTH zero items and zero bytes
  // (app.js:3701); a non-zero estimate still renders the sized breakdown.
  if (totalItems == 0 && sizeBytes <= 0) return 'No cached data on device yet';

  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  final breakdown =
      '${plural(channels, 'channel')}, ${plural(pms, 'PM/group thread')}, '
      '${plural(profiles, 'profile')}, ${plural(reactions, 'reaction record')}';
  return '${formatCacheBytes(sizeBytes)} cached on device — $breakdown';
}

/// Formats a byte count as a fixed-unit "MB" string. Retained for tests; the
/// live Data & Backup readout uses the PWA's auto-scaled [formatCacheBytes]
/// via [cacheReadoutFor] (app.js:3631 `formatCacheBytes`).
String formatCacheMb(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  final fixed = mb >= 10 ? 0 : 1;
  return '${mb.toStringAsFixed(fixed)} MB';
}

/// Formats a byte count into a short auto-scaled human string (app.js:3631
/// `formatCacheBytes`): B/KB/MB/GB, one decimal below 10 (except bytes).
String formatCacheBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  double n = bytes.toDouble();
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  final fixed = (n >= 10 || i == 0) ? 0 : 1;
  return '${n.toStringAsFixed(fixed)} ${units[i]}';
}

/// Formats an inbound settings-transfer timestamp (unix seconds) as a compact
/// local date-time for the Pending Settings Transfers row (F17). Mirrors the
/// PWA's `new Date(transferredAt * 1000).toLocaleString()` (shop.js:2006) with a
/// dependency-free `YYYY-MM-DD HH:MM` rendering.
String formatTransferTimestamp(int unixSeconds) {
  if (unixSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// Abbreviates a hex pubkey as `<first16>…<last8>` for the transfer row's
/// "Verified sender key" line (shop.js:2011).
String abbreviateTransferKey(String pubkey) {
  if (pubkey.length <= 24) return pubkey;
  return '${pubkey.substring(0, 16)}…${pubkey.substring(pubkey.length - 8)}';
}

/// The exact `nym_*` keys wiped by "Reset Settings to Defaults"
/// (app.js:4048-4073 `SETTINGS_KEY_EXACT`). Identity/login/PM/group/shop keys
/// are deliberately absent so they are preserved.
const List<String> kSettingsResetKeys = [
  'nym_theme', 'nym_color_mode',
  'nym_chat_layout',
  'nym_wallpaper_type', 'nym_wallpaper_custom_url',
  'nym_text_size', 'nym_transparency_enabled', 'nym_nick_style',
  'nym_show_status',
  'nym_autoscroll', 'nym_timestamps', 'nym_time_format', 'nym_date_format',
  'nym_sound', 'nym_notifications_enabled', 'nym_notify_friends_only',
  'nym_sort_proximity',
  'nym_dm_fwdsec_enabled', 'nym_dm_ttl_seconds',
  'nym_read_receipts_enabled', 'nym_typing_indicators_enabled',
  'nym_accept_pms', 'nym_cache_pms', 'nym_sync_mls_history',
  'nym_groupchat_pm_only_mode', 'nym_low_data_mode',
  'nym_pow_difficulty',
  'nym_pinned_channels', 'nym_pinned_landing_channel',
  'nym_hidden_channels', 'nym_hide_non_pinned',
  'nym_blocked', 'nym_blocked_channels', 'nym_blocked_keywords',
  'nym_image_blur',
  'nym_group_notify_mentions_only',
  'nym_recent_emojis',
  'nym_user_channels', 'nym_user_joined_channels',
  'nym_relay_url',
  'nym_nav',
  'nym_tutorial_seen', 'nym_botpm_welcomed',
  'nym_notification_history', 'nym_notification_last_read',
  'nym_notification_seen',
];

/// The key prefixes also wiped on reset (`SETTINGS_KEY_PREFIXES`).
const List<String> kSettingsResetKeyPrefixes = ['nym_image_blur_'];

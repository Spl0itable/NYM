import 'dart:convert';

import '../../core/crypto/key_format.dart' show normalizePubkeyInput;
import '../../core/constants/storage_keys.dart';
import '../../models/channel.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/app_state.dart';
import '../i18n/i18n.dart';

/// Side-effect-free helpers for the Settings modal's data features.

/// `"37.77°N, 122.41°W"` for a geohash; empty on decode failure.
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

/// Pinned landing channel, persisted as JSON like `{"type":"geohash","geohash":"nymchat"}`.
class LandingChannel {
  const LandingChannel({this.type = 'geohash', required this.geohash});

  final String type;
  final String geohash;

  static const LandingChannel defaultChannel =
      LandingChannel(geohash: 'nymchat');

  String toJsonString() => jsonEncode({'type': type, 'geohash': geohash});

  /// `#<geohash>` or `#<geohash> (location)`.
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
      other is LandingChannel && other.type == type && other.geohash == geohash;

  @override
  int get hashCode => Object.hash(type, geohash);
}

class LandingChannelOption {
  const LandingChannelOption({
    required this.group,
    required this.value,
  });

  /// `'Common Geohash Channels'` or `'Joined Geohash Channels'`.
  final String group;
  final LandingChannel value;

  String get label => value.label;

  /// Lowercased `"<geohash> <location>"` for type-to-filter.
  String get searchText =>
      ('${value.geohash} ${geohashLocationLabel(value.geohash)}')
          .trim()
          .toLowerCase();
}

/// Persisted landing channel, default `nymchat`.
LandingChannel readLandingChannel(KeyValueStore kv) {
  return LandingChannel.tryParse(
          kv.getString(StorageKeys.pinnedLandingChannel)) ??
      LandingChannel.defaultChannel;
}

void writeLandingChannel(KeyValueStore kv, LandingChannel channel) {
  kv.setString(StorageKeys.pinnedLandingChannel, channel.toJsonString());
}

/// The 10 common geohashes first, then joined geohash channels not already listed.
List<LandingChannelOption> buildLandingChannelOptions(
  List<ChannelEntry> channels, {
  List<String> commonGeohashes = const [
    'nymchat',
    '9q',
    'w2',
    'dr5r',
    '9q8y',
    'u4pr',
    'gcpv',
    'f2m6',
    'xn77',
    'tjm5',
  ],
}) {
  final out = <LandingChannelOption>[];
  final seen = <String>{};
  for (final g in commonGeohashes) {
    if (!seen.add(g)) continue;
    out.add(LandingChannelOption(
      group: tr('Common Geohash Channels'),
      value: LandingChannel(geohash: g),
    ));
  }
  // `nymchat` is a named channel, so it never double-counts here.
  for (final c in channels) {
    final key = c.key;
    if (!isValidGeohash(key)) continue;
    if (commonGeohashes.contains(key)) continue;
    if (!seen.add(key)) continue;
    out.add(LandingChannelOption(
      group: tr('Joined Geohash Channels'),
      value: LandingChannel(geohash: key),
    ));
  }
  return out;
}

/// The five valid read-receipt and typing-indicator scopes.
const List<String> kIndicatorScopes = [
  'disabled',
  'pms',
  'groups',
  'pms-groups',
  'everywhere',
];

/// Legacy `'true'`/`'false'` map to everywhere/disabled; other invalid values fall back to [fallback].
String normalizeIndicatorScope(String? value,
    {String fallback = 'pms-groups'}) {
  if (value == 'true') return 'everywhere';
  if (value == 'false') return 'disabled';
  if (value != null && kIndicatorScopes.contains(value)) return value;
  return fallback;
}

/// An npub or 64-char hex key that isn't the user's own; returns the error string, or null when valid.
String? validateTransferPubkey(String input, {required String selfPubkey}) {
  final pk = normalizePubkeyInput(input);
  if (pk == null) {
    return tr('Invalid public key. Paste an npub or a 64-character hex pubkey.');
  }
  if (selfPubkey.isNotEmpty && pk == selfPubkey.toLowerCase()) {
    return tr('Cannot transfer settings to yourself.');
  }
  return null;
}

/// On-device cache readout; a positive [realBytes] (on-disk size) is preferred over the content estimate.
String cacheReadoutFor(AppState s, {int realBytes = 0}) {
  var channels = 0;
  var pms = 0;
  var bytes = 0;
  s.messages.forEach((key, list) {
    if (list.isEmpty) return;
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
  // Empty state requires both zero items and zero bytes.
  if (totalItems == 0 && sizeBytes <= 0) {
    return tr('No cached data on device yet');
  }

  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  final breakdown =
      '${plural(channels, tr('channel'))}, ${plural(pms, tr('PM/group thread'))}, '
      '${plural(profiles, tr('profile'))}, ${plural(reactions, tr('reaction record'))}';
  return tr('{size} cached on device — {breakdown}',
      {'size': formatCacheBytes(sizeBytes), 'breakdown': breakdown});
}

/// Fixed-unit "MB" string, kept for tests; the live readout uses [formatCacheBytes].
String formatCacheMb(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  final fixed = mb >= 10 ? 0 : 1;
  return '${mb.toStringAsFixed(fixed)} MB';
}

/// Auto-scaled B/KB/MB/GB, one decimal below 10 (except bytes).
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

/// Local `YYYY-MM-DD HH:MM` for a settings-transfer timestamp in unix seconds.
String formatTransferTimestamp(int unixSeconds) {
  if (unixSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// `<first16>…<last8>` pubkey abbreviation.
String abbreviateTransferKey(String pubkey) {
  if (pubkey.length <= 24) return pubkey;
  return '${pubkey.substring(0, 16)}…${pubkey.substring(pubkey.length - 8)}';
}

/// Exact keys wiped by "Reset Settings to Defaults"; identity, login, PM, group and shop keys are deliberately absent.
const List<String> kSettingsResetKeys = [
  'nym_theme',
  'nym_color_mode',
  'nym_chat_layout',
  'nym_wallpaper_type',
  'nym_wallpaper_custom_url',
  'nym_text_size',
  'nym_transparency_enabled',
  'nym_nick_style',
  'nym_show_status',
  'nym_autoscroll',
  'nym_timestamps',
  'nym_time_format',
  'nym_date_format',
  'nym_sound',
  'nym_notifications_enabled',
  'nym_notify_friends_only',
  'nym_sort_proximity',
  'nym_dm_fwdsec_enabled',
  'nym_dm_ttl_seconds',
  'nym_read_receipts_enabled',
  'nym_typing_indicators_enabled',
  'nym_accept_pms',
  'nym_cache_pms',
  'nym_sync_mls_history',
  'nym_groupchat_pm_only_mode',
  'nym_low_data_mode',
  'nym_pow_difficulty',
  'nym_pinned_channels',
  'nym_pinned_landing_channel',
  'nym_hidden_channels',
  'nym_hide_non_pinned',
  'nym_blocked',
  'nym_blocked_channels',
  'nym_blocked_keywords',
  'nym_image_blur',
  'nym_group_notify_mentions_only',
  'nym_recent_emojis',
  'nym_user_channels',
  'nym_user_joined_channels',
  'nym_relay_url',
  'nym_nav',
  'nym_tutorial_seen',
  'nym_botpm_welcomed',
  'nym_notification_history',
  'nym_notification_last_read',
  'nym_notification_seen',
];

/// Key prefixes also wiped on reset.
const List<String> kSettingsResetKeyPrefixes = ['nym_image_blur_'];

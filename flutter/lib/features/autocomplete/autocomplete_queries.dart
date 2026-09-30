// Pure query engines for the four composer autocompletes, each capped at [kAutocompleteMax] results.

import '../../core/utils/nym_utils.dart';
import '../../features/globe/geo_projection.dart' show geohashBounds;
import '../../models/channel.dart';
import '../../models/user.dart';
import '../emoji/custom_emoji.dart';
import '../emoji/emoji_data.dart';

const int kAutocompleteMax = 8;

/// The 10 seed channels always offered; `nymchat` is named, the rest are geohash prefixes.
const List<String> kCommonGeohashes = [
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
];

class MentionResult {
  const MentionResult({
    required this.pubkey,
    required this.nym,
    required this.baseNym,
    required this.suffix,
    required this.status,
    this.avatarUrl,
  });

  final String pubkey;
  final String nym;
  final String baseNym;
  final String suffix;
  final UserStatus status;

  /// Remote avatar URL; null falls back to an identicon.
  final String? avatarUrl;

  /// Inserted text `@base#suffix ` with a trailing space.
  String get insertText => '@$baseNym#$suffix ';
}

/// Filters by `base#suffix`, excludes [blocked], and orders members then others by online/away/offline, then name.
List<MentionResult> queryMentions({
  required Map<String, User> users,
  required String search,
  required String currentChannelKey,
  Set<String> blocked = const {},
  Set<String> verifiedBots = const {},
  Set<String>? priority,
  int? nowMs,
}) {
  final needle = search.toLowerCase();
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

  final channelOnline = <MentionResult>[];
  final channelAway = <MentionResult>[];
  final channelOffline = <MentionResult>[];
  final otherOnline = <MentionResult>[];
  final otherAway = <MentionResult>[];
  final otherOffline = <MentionResult>[];

  users.forEach((pubkey, user) {
    if (blocked.contains(pubkey)) return;
    final baseNym = stripPubkeySuffix(user.nym);
    final suffix = getPubkeySuffix(pubkey);
    final searchable = '$baseNym#$suffix';
    if (!searchable.toLowerCase().contains(needle)) return;

    final status = user.effectiveStatus(
        nowMs: now, isVerifiedBot: verifiedBots.contains(pubkey));
    final entry = MentionResult(
      pubkey: pubkey,
      nym: user.nym,
      baseNym: baseNym,
      suffix: suffix,
      status: status,
      avatarUrl: user.profile?.picture,
    );

    final inChannel = user.channels.contains(currentChannelKey) ||
        (priority != null && priority.contains(pubkey));

    if (inChannel) {
      switch (status) {
        case UserStatus.online:
          channelOnline.add(entry);
        case UserStatus.away:
          channelAway.add(entry);
        default:
          channelOffline.add(entry);
      }
    } else {
      switch (status) {
        case UserStatus.online:
          otherOnline.add(entry);
        case UserStatus.away:
          otherAway.add(entry);
        default:
          otherOffline.add(entry);
      }
    }
  });

  int alpha(MentionResult a, MentionResult b) =>
      '${a.baseNym}#${a.suffix}'.compareTo('${b.baseNym}#${b.suffix}');
  for (final bucket in [
    channelOnline,
    channelAway,
    channelOffline,
    otherOnline,
    otherAway,
    otherOffline,
  ]) {
    bucket.sort(alpha);
  }

  return [
    ...channelOnline,
    ...channelAway,
    ...channelOffline,
    ...otherOnline,
    ...otherAway,
    ...otherOffline,
  ].take(kAutocompleteMax).toList();
}

class ChannelResult {
  const ChannelResult({
    required this.name,
    required this.messageCount,
    required this.isJoined,
    required this.isCurrent,
    required this.isGeohash,
    this.location = '',
  });

  final String name;
  final int messageCount;
  final bool isJoined;
  final bool isCurrent;
  final bool isGeohash;

  /// Decoded-center coordinate label for geohash channels; empty otherwise.
  final String location;

  String get insertText => '#$name ';
}

/// `"{lat}°{N|S}, {lng}°{E|W}"` (2 decimals) for the cell center, or '' when not decodable.
String geohashLocationLabel(String geohash) {
  final b = geohashBounds(geohash);
  if (b == null) return '';
  final lat = (b.latLo + b.latHi) / 2;
  final lng = (b.lngLo + b.lngHi) / 2;
  final latStr = '${lat.abs().toStringAsFixed(2)}°${lat >= 0 ? 'N' : 'S'}';
  final lngStr = '${lng.abs().toStringAsFixed(2)}°${lng >= 0 ? 'E' : 'W'}';
  return '$latStr, $lngStr';
}

final RegExp _validChannelRe = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);

/// Sources: channels with messages, joined channels, then seeds; sorted current, joined, message count, name.
List<ChannelResult> queryChannels({
  required String search,
  required List<ChannelEntry> channels,
  required Map<String, int> messageChannelCounts,
  required String currentKey,
  Set<String> joinedKeys = const {},
}) {
  final map = <String, ChannelResult>{};
  final searchLower = search.toLowerCase();

  // Keys are bare channel names here.
  messageChannelCounts.forEach((name, count) {
    final geo = isValidGeohash(name);
    map[name] = ChannelResult(
      name: name,
      messageCount: count,
      isJoined: joinedKeys.contains(name) || channels.any((c) => c.key == name),
      isCurrent: name == currentKey,
      isGeohash: geo,
      location: geo ? geohashLocationLabel(name) : '',
    );
  });

  for (final ch in channels) {
    final key = ch.key;
    if (map.containsKey(key)) continue;
    map[key] = ChannelResult(
      name: key,
      messageCount: messageChannelCounts[key] ?? 0,
      isJoined: true,
      isCurrent: key == currentKey,
      isGeohash: ch.isGeohash,
      location: ch.isGeohash ? geohashLocationLabel(key) : '',
    );
  }

  for (final g in kCommonGeohashes) {
    if (map.containsKey(g)) continue;
    final geo = isValidGeohash(g);
    map[g] = ChannelResult(
      name: g,
      messageCount: messageChannelCounts[g] ?? 0,
      isJoined: joinedKeys.contains(g) || channels.any((c) => c.key == g),
      isCurrent: g == currentKey,
      isGeohash: geo,
      location: geo ? geohashLocationLabel(g) : '',
    );
  }

  final matches = map.values
      .where((ch) =>
          _validChannelRe.hasMatch(ch.name) &&
          ch.name.toLowerCase().contains(searchLower))
      .toList();

  matches.sort((a, b) {
    if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
    if (a.isJoined != b.isJoined) return a.isJoined ? -1 : 1;
    if (a.messageCount != b.messageCount) {
      return b.messageCount.compareTo(a.messageCount);
    }
    return a.name.compareTo(b.name);
  });

  return matches.take(kAutocompleteMax).toList();
}

/// One emoji row; for NIP-30 custom emoji [customUrl] is set and [emoji] is the `:shortcode:` token.
class EmojiResult {
  const EmojiResult({required this.name, required this.emoji, this.customUrl});

  final String name;
  final String emoji;
  final String? customUrl;

  bool get isCustom => customUrl != null;

  String get insertText => '$emoji ';
}

/// Searchable emoji index; priority 1 = named (map or custom), 2 = category-only.
List<({String name, String emoji, int priority, String? customUrl})>
    _buildEmojiIndex(CustomEmojiState custom) {
  final entries =
      <({String name, String emoji, int priority, String? customUrl})>[];
  final seenEmoji = <String>{};

  kEmojiShortcodeMap.forEach((name, emoji) {
    entries.add((name: name, emoji: emoji, priority: 1, customUrl: null));
    seenEmoji.add(emoji);
  });

  for (final list in kEmojisByCategory.values) {
    for (final emoji in list) {
      if (seenEmoji.contains(emoji)) continue;
      seenEmoji.add(emoji);
      entries.add((name: emoji, emoji: emoji, priority: 2, customUrl: null));
    }
  }

  custom.codeToUrl.forEach((shortcode, url) {
    entries.add((
      name: shortcode,
      emoji: ':$shortcode:',
      priority: 1,
      customUrl: url,
    ));
  });

  return entries;
}

/// Empty search: recents, then 10 others, capped; otherwise match name or emoji ranked exact, prefix, priority, length.
List<EmojiResult> queryEmoji({
  required String search,
  List<String> recents = const [],
  CustomEmojiState custom = CustomEmojiState.empty,
}) {
  final index = _buildEmojiIndex(custom);

  if (search.isEmpty) {
    final recentSet = recents.toSet();
    final emojiToNames = <String, String>{};
    kEmojiShortcodeMap.forEach((name, emoji) {
      emojiToNames.putIfAbsent(emoji, () => name);
    });
    // Custom recents still in the live map render as images; label colons are stripped.
    final result = <EmojiResult>[
      for (final e in recents) _recentEmojiResult(e, emojiToNames, custom),
      ...index.where((e) => !recentSet.contains(e.emoji)).take(10).map((e) =>
          EmojiResult(name: e.name, emoji: e.emoji, customUrl: e.customUrl)),
    ];
    return result.take(kAutocompleteMax).toList();
  }

  final searchLower = search.toLowerCase();
  final matches = index
      .where((e) =>
          e.name.toLowerCase().contains(searchLower) ||
          e.emoji.contains(search))
      .toList();

  matches.sort((a, b) {
    final aName = a.name.toLowerCase();
    final bName = b.name.toLowerCase();
    final aExact = aName == searchLower ? 0 : 1;
    final bExact = bName == searchLower ? 0 : 1;
    if (aExact != bExact) return aExact - bExact;
    final aPrefix = aName.startsWith(searchLower) ? 0 : 1;
    final bPrefix = bName.startsWith(searchLower) ? 0 : 1;
    if (aPrefix != bPrefix) return aPrefix - bPrefix;
    if (a.priority != b.priority) return a.priority - b.priority;
    return aName.length - bName.length;
  });

  return matches
      .take(kAutocompleteMax)
      .map((e) =>
          EmojiResult(name: e.name, emoji: e.emoji, customUrl: e.customUrl))
      .toList();
}

final _customEmojiTokenRe = RegExp(r'^:([a-zA-Z0-9_]+):$');

/// Custom recents still in [custom] carry a [customUrl]; label colons are stripped.
EmojiResult _recentEmojiResult(
    String e, Map<String, String> emojiToNames, CustomEmojiState custom) {
  final cm = _customEmojiTokenRe.firstMatch(e);
  if (cm != null) {
    final code = cm.group(1)!;
    final url = custom.codeToUrl[code];
    if (url != null) {
      return EmojiResult(name: code, emoji: e, customUrl: url);
    }
  }
  // Unicode or unknown token: strip wrapping colons from the resolved name.
  final name = emojiToNames[e] ?? e;
  return EmojiResult(name: name.replaceAll(RegExp(r'^:+|:+$'), ''), emoji: e);
}

/// Kaomoji categories grouped by mood.
const List<(String, List<String>)> kKaomojiCategories = [
  (
    'Joy',
    ['(◕‿◕)', '(◠‿◠)', '(*^‿^*)', '(≧◡≦)', 'ヽ(•‿•)ノ', '(´∇｀)', '＼(^o^)／']
  ),
  ('Love', ['(♥‿♥)', '(づ｡◕‿‿◕｡)づ', '♡(◡‿◡)', '(*♡∀♡)', '(❤ω❤)']),
  ('Sad', ['(╥﹏╥)', '(｡•́︿•̀｡)', '(T_T)', '(ಥ_ಥ)', '(´；ω；`)', 'orz']),
  ('Anger', ['(╬ಠ益ಠ)', 'ヽ(`Д´)ﾉ', '(ノಠ益ಠ)ノ', '凸(￣ヘ￣)', '(＃`Д´)']),
  ('Surprise', ['(⊙_⊙)', '(°ロ°)', 'Σ(°△°)', '(ﾟοﾟ)']),
  ('Confused', ['¯\\_(ツ)_/¯', '(•_•)?', '(°ヘ°)', '(￣～￣;)']),
  ('Tableflip', ['(╯°□°)╯︵ ┻━┻', '┬─┬ノ( º_ºノ)', '(ノಠ益ಠ)ノ彡┻━┻']),
  ('Animals', ['(=^･ω･^=)', 'ʕ•ᴥ•ʔ', '(•ㅅ•)', '/ᐠ｡ꞈ｡ᐟ\\', '>°)))彡']),
  ('Misc', ['(☞ﾟヮﾟ)☞', 'ᕦ(ò_óˇ)ᕤ', '(⌐■_■)', '(◔_◔)', '~(˘▽˘~)']),
];

/// Category header plus rows, interleaved in the dropdown.
class KaomojiSection {
  const KaomojiSection(this.label, this.items);
  final String label;
  final List<String> items;
}

/// Filters categories by label substring; unlike other lists, kaomoji aren't capped.
List<KaomojiSection> queryKaomoji({required String search}) {
  final needle = search.toLowerCase();
  final cats = needle.isEmpty
      ? kKaomojiCategories
      : kKaomojiCategories
          .where((c) => c.$1.toLowerCase().contains(needle))
          .toList();
  return cats.map((c) => KaomojiSection(c.$1, c.$2)).toList();
}

String kaomojiInsertText(String kaomoji) => '$kaomoji ';

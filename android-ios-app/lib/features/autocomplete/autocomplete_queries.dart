// Pure query engines for the four composer autocompletes, ported 1:1 from
// `js/modules/autocomplete.js` (docs/specs/03 §8). Each returns at most
// [kAutocompleteMax] = 8 results, matching the PWA's `.slice(0, 8)` cap.
//
// These are side-effect-free so they can be unit-tested directly and reused by
// the dropdown widget. The widget owns rendering + keyboard nav; insertion
// (splicing the chosen token back into the input) lives in the composer.

import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../emoji/custom_emoji.dart';
import '../emoji/emoji_data.dart';

/// Max results per dropdown (`.slice(0, 8)` everywhere in autocomplete.js).
const int kAutocompleteMax = 8;

/// The 10 seed channels the PWA always offers (app.js:681 `commonGeohashes`).
/// `nymchat` is the named default; the rest are geohash prefixes.
const List<String> kCommonGeohashes = [
  'nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5',
];

// ---------------------------------------------------------------------------
// @ mentions (showAutocomplete, autocomplete.js:276)
// ---------------------------------------------------------------------------

/// One mention row.
class MentionResult {
  const MentionResult({
    required this.pubkey,
    required this.nym,
    required this.baseNym,
    required this.suffix,
    required this.status,
  });

  final String pubkey;
  final String nym;
  final String baseNym;
  final String suffix;
  final UserStatus status;

  /// The text inserted into the composer: `@base#suffix ` (note trailing space),
  /// matching `selectAutocomplete` (autocomplete.js:503).
  String get insertText => '@$baseNym#$suffix ';
}

/// Ranks users for an `@` mention. Filters by `base#suffix` substring (case-
/// insensitive), excludes [blocked] pubkeys, and orders:
/// channel members (online → away → offline) then others (online → away →
/// offline), alphabetical within each bucket — exactly showAutocomplete.
///
/// [currentChannelKey] is the active channel key (geohash or name). [priority]
/// is the PM-peer / group-member set that should be treated as "in channel"
/// (`_mentionPriorityPubkeys`).
List<MentionResult> queryMentions({
  required Map<String, User> users,
  required String search,
  required String currentChannelKey,
  Set<String> blocked = const {},
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

    final status = user.effectiveStatus(nowMs: now);
    final entry = MentionResult(
      pubkey: pubkey,
      nym: user.nym,
      baseNym: baseNym,
      suffix: suffix,
      status: status,
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

// ---------------------------------------------------------------------------
// # channels (showChannelAutocomplete, autocomplete.js:521)
// ---------------------------------------------------------------------------

/// One channel row.
class ChannelResult {
  const ChannelResult({
    required this.name,
    required this.messageCount,
    required this.isJoined,
    required this.isCurrent,
    required this.isGeohash,
  });

  final String name;
  final int messageCount;
  final bool isJoined;
  final bool isCurrent;
  final bool isGeohash;

  /// Inserted text: `#name ` (insertChannelReference, autocomplete.js:684).
  String get insertText => '#$name ';
}

final RegExp _validChannelRe = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);

/// Ranks channels for a `#` reference. Sources, in PWA order: channels we have
/// messages for (keys of [messageChannelCounts], `#`-stripped), joined sidebar
/// [channels], then [kCommonGeohashes]. Filters to valid names containing
/// [search]; sorts current → joined → message count desc → name.
List<ChannelResult> queryChannels({
  required String search,
  required List<ChannelEntry> channels,
  required Map<String, int> messageChannelCounts,
  required String currentKey,
  Set<String> joinedKeys = const {},
}) {
  final map = <String, ChannelResult>{};
  final searchLower = search.toLowerCase();

  // From messages we have (keys are bare channel names here).
  messageChannelCounts.forEach((name, count) {
    map[name] = ChannelResult(
      name: name,
      messageCount: count,
      isJoined: joinedKeys.contains(name) ||
          channels.any((c) => c.key == name),
      isCurrent: name == currentKey,
      isGeohash: isValidGeohash(name),
    );
  });

  // From sidebar channels.
  for (final ch in channels) {
    final key = ch.key;
    if (map.containsKey(key)) continue;
    map[key] = ChannelResult(
      name: key,
      messageCount: messageChannelCounts[key] ?? 0,
      isJoined: true,
      isCurrent: key == currentKey,
      isGeohash: ch.isGeohash,
    );
  }

  // From the seed common geohashes.
  for (final g in kCommonGeohashes) {
    if (map.containsKey(g)) continue;
    map[g] = ChannelResult(
      name: g,
      messageCount: messageChannelCounts[g] ?? 0,
      isJoined: joinedKeys.contains(g) || channels.any((c) => c.key == g),
      isCurrent: g == currentKey,
      isGeohash: isValidGeohash(g),
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

// ---------------------------------------------------------------------------
// : emoji (showEmojiAutocomplete, autocomplete.js:25)
// ---------------------------------------------------------------------------

/// One emoji row. [customUrl] is set for NIP-30 custom emoji (rendered as an
/// image; [emoji] is then the `:shortcode:` token to insert).
class EmojiResult {
  const EmojiResult({required this.name, required this.emoji, this.customUrl});

  final String name;
  final String emoji;
  final String? customUrl;

  bool get isCustom => customUrl != null;

  /// Inserted text: the emoji (or `:shortcode:`) + a trailing space
  /// (selectSpecificEmojiAutocomplete, autocomplete.js:184).
  String get insertText => '$emoji ';
}

/// Builds the searchable emoji index from the shortcode map, the categorized
/// unicode set, and any custom emoji — mirroring the `allEmojiEntries` assembly
/// in showEmojiAutocomplete. `priority` 1 = named (emojiMap/custom), 2 =
/// category-only (no shortcode name).
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

/// Resolves the `:` emoji dropdown. Empty [search] → recents first, then the
/// first 10 non-recent entries, capped to 8. Non-empty → fuzzy match on name OR
/// emoji, ranked exact → prefix → priority → shorter-name (the exact comparator
/// in showEmojiAutocomplete).
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
    final result = <EmojiResult>[
      for (final e in recents)
        EmojiResult(name: emojiToNames[e] ?? e, emoji: e),
      ...index
          .where((e) => !recentSet.contains(e.emoji))
          .take(10)
          .map((e) =>
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

// ---------------------------------------------------------------------------
// \ kaomoji (showKaomojiAutocomplete, autocomplete.js:192)
// ---------------------------------------------------------------------------

/// Kaomoji categories grouped by mood — verbatim from `kaomojiCategories`
/// (commands.js:332).
const List<(String, List<String>)> kKaomojiCategories = [
  ('Joy', ['(◕‿◕)', '(◠‿◠)', '(*^‿^*)', '(≧◡≦)', 'ヽ(•‿•)ノ', '(´∇｀)', '＼(^o^)／']),
  ('Love', ['(♥‿♥)', '(づ｡◕‿‿◕｡)づ', '♡(◡‿◡)', '(*♡∀♡)', '(❤ω❤)']),
  ('Sad', ['(╥﹏╥)', '(｡•́︿•̀｡)', '(T_T)', '(ಥ_ಥ)', '(´；ω；`)', 'orz']),
  ('Anger', ['(╬ಠ益ಠ)', 'ヽ(`Д´)ﾉ', '(ノಠ益ಠ)ノ', '凸(￣ヘ￣)', '(＃`Д´)']),
  ('Surprise', ['(⊙_⊙)', '(°ロ°)', 'Σ(°△°)', '(ﾟοﾟ)']),
  ('Confused', ['¯\\_(ツ)_/¯', '(•_•)?', '(°ヘ°)', '(￣～￣;)']),
  ('Tableflip', ['(╯°□°)╯︵ ┻━┻', '┬─┬ノ( º_ºノ)', '(ノಠ益ಠ)ノ彡┻━┻']),
  ('Animals', ['(=^･ω･^=)', 'ʕ•ᴥ•ʔ', '(•ㅅ•)', '/ᐠ｡ꞈ｡ᐟ\\', '>°)))彡']),
  ('Misc', ['(☞ﾟヮﾟ)☞', 'ᕦ(ò_óˇ)ᕤ', '(⌐■_■)', '(◔_◔)', '~(˘▽˘~)']),
];

/// A kaomoji category section (header + rows), used by the dropdown which, like
/// the PWA, renders category headers interleaved with selectable rows.
class KaomojiSection {
  const KaomojiSection(this.label, this.items);
  final String label;
  final List<String> items;
}

/// Filters kaomoji categories by label substring (showKaomojiAutocomplete).
/// Empty [search] returns all categories. Note: the PWA does NOT cap kaomoji to
/// 8 (the cap is only on the flat result lists); we preserve that.
List<KaomojiSection> queryKaomoji({required String search}) {
  final needle = search.toLowerCase();
  final cats = needle.isEmpty
      ? kKaomojiCategories
      : kKaomojiCategories
          .where((c) => c.$1.toLowerCase().contains(needle))
          .toList();
  return cats.map((c) => KaomojiSection(c.$1, c.$2)).toList();
}

/// Inserted text for a kaomoji: the kaomoji + a trailing space (selectKaomoji).
String kaomojiInsertText(String kaomoji) => '$kaomoji ';

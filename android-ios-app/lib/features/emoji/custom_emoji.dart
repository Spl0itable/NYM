// NIP-30 custom emoji cache + packs, loaded from the same SharedPreferences /
// localStorage keys the PWA persists (emoji.js `_loadCustomEmojiCache`,
// lines 8-24): `nym_custom_emojis` (loose [shortcode,url] pairs, ≤5000) and
// `nym_custom_emoji_packs` (pack objects, ≤200).
//
// The Flutter NostrController is read-only for this feature and does not yet
// surface live NIP-30 events, so we hydrate from the persisted cache only,
// exactly as the PWA does at startup. Packs/codes that arrive live over relays
// are out of scope here.
//
// TODO(verify): if/when the NostrController exposes a live customEmojis stream
// (30030/10030 + message `emoji` tags), wire it in alongside the cache.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emoji_data.dart';

/// localStorage keys (emoji.js lines 13, 21).
const String kCustomEmojiMapKey = 'nym_custom_emojis';
const String kCustomEmojiPacksKey = 'nym_custom_emoji_packs';

/// Shortcode regex (emoji.js `_RX_EMOJI_SHORTCODE`).
final RegExp _rxShortcode = RegExp(r'^[a-zA-Z0-9_]+$');

/// URL must be http(s) (emoji.js `_RX_EMOJI_URL`).
final RegExp _rxUrl = RegExp(r'^https?://', caseSensitive: false);

/// One NIP-30 emoji pack (kind 30030). Mirrors the PWA's pack shape used in
/// `buildCustomEmojiSectionsHtml`.
class CustomEmojiPack {
  const CustomEmojiPack({
    required this.pubkey,
    required this.identifier,
    required this.title,
    required this.createdAt,
    required this.emojis,
  });

  final String pubkey;
  final String identifier;
  final String title;
  final int createdAt;

  /// (shortcode, url) entries, ≤120 (emoji.js `handleEmojiPackEvent`).
  final List<({String shortcode, String url})> emojis;

  /// `${pubkey}:${identifier}` (emoji.js `_emojiPackKey`).
  String get key => '$pubkey:$identifier';
}

/// Immutable snapshot of all known custom emoji.
class CustomEmojiState {
  const CustomEmojiState({
    this.codeToUrl = const {},
    this.packs = const [],
  });

  /// shortcode -> original (un-proxied) image url. Mirrors `customEmojis`.
  final Map<String, String> codeToUrl;

  /// Loaded packs, dedup'd by [CustomEmojiPack.key].
  final List<CustomEmojiPack> packs;

  bool get isEmpty => codeToUrl.isEmpty;

  static const empty = CustomEmojiState();
}

/// Loads the custom-emoji caches from SharedPreferences and applies the same
/// validation rules as `registerCustomEmoji` (emoji.js lines 117-130):
/// valid shortcode + http(s) url, and never shadowing a built-in unicode
/// shortcode (`kEmojiShortcodeMap`).
CustomEmojiState loadCustomEmojiState(SharedPreferences prefs) {
  final codeToUrl = <String, String>{};

  void register(String? shortcode, String? url) {
    if (shortcode == null || url == null) return;
    if (!_rxShortcode.hasMatch(shortcode) || !_rxUrl.hasMatch(url)) return;
    // Don't let custom emoji shadow built-in unicode shortcodes (emoji.js:121).
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return;
    codeToUrl[shortcode] = url;
  }

  // Loose map: array of [shortcode, url] pairs (emoji.js lines 12-19).
  final rawMap = prefs.getString(kCustomEmojiMapKey);
  if (rawMap != null && rawMap.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawMap);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is List && entry.length >= 2) {
            register(entry[0] as String?, entry[1] as String?);
          }
        }
      }
    } catch (_) {}
  }

  // Packs (emoji.js lines 20-23, `_storeEmojiPack`).
  final packs = <CustomEmojiPack>[];
  final seenPackKeys = <String>{};
  final rawPacks = prefs.getString(kCustomEmojiPacksKey);
  if (rawPacks != null && rawPacks.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawPacks);
      if (decoded is List) {
        for (final p in decoded) {
          if (p is! Map) continue;
          final pubkey = p['pubkey'] as String?;
          final rawEmojis = p['emojis'];
          if (pubkey == null || rawEmojis is! List || rawEmojis.isEmpty) {
            continue;
          }
          final identifier = (p['identifier'] as String?) ?? '';
          final key = '$pubkey:$identifier';
          if (seenPackKeys.contains(key)) continue;
          final emojis = <({String shortcode, String url})>[];
          for (final e in rawEmojis) {
            if (e is! Map) continue;
            final sc = e['shortcode'] as String?;
            final url = e['url'] as String?;
            if (sc == null || url == null) continue;
            if (!_rxShortcode.hasMatch(sc) || !_rxUrl.hasMatch(url)) continue;
            emojis.add((shortcode: sc, url: url));
            register(sc, url);
          }
          if (emojis.isEmpty) continue;
          seenPackKeys.add(key);
          packs.add(CustomEmojiPack(
            pubkey: pubkey,
            identifier: identifier,
            title: (p['title'] as String?) ?? identifier,
            createdAt: (p['created_at'] as num?)?.toInt() ?? 0,
            emojis: emojis,
          ));
        }
      }
    } catch (_) {}
  }

  // Newest packs first (emoji.js sorts favorites/own/subscribed first, then by
  // created_at desc; without live ownership info we approximate with recency).
  packs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return CustomEmojiState(codeToUrl: codeToUrl, packs: packs);
}

/// Proxied URL for a custom emoji image (emoji.js `getProxiedEmojiUrl`,
/// users.js:493). When no proxy base is configured, returns the url verbatim.
String proxiedEmojiUrl(String url, String? proxyBase) {
  if (proxyBase == null || proxyBase.isEmpty) return url;
  return '$proxyBase?emoji=1&url=${Uri.encodeQueryComponent(url)}';
}

/// Provider that exposes the cached custom-emoji state. Overridden where the
/// picker mounts (and in tests). Default is empty so nothing reads prefs at
/// import time.
final customEmojiStateProvider = Provider<CustomEmojiState>(
  (ref) => CustomEmojiState.empty,
);

/// Lazily-resolved SharedPreferences for the emoji/GIF stores. Async so the
/// composer can build the recents/favorites stores and custom-emoji snapshot
/// only when a picker is actually opened. Overridable in tests.
final emojiPrefsProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

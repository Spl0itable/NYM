// Startup hydration of NIP-30 custom emoji and packs; live updates are `LiveCustomEmojiNotifier` in app_state.dart.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api/api_config.dart';
import '../../services/storage/revocable_prefs.dart';

import 'emoji_data.dart';

/// Persisted keys: loose [shortcode,url] pairs (max 5000) and packs (max 200).
const String kCustomEmojiMapKey = 'nym_custom_emojis';
const String kCustomEmojiPacksKey = 'nym_custom_emoji_packs';

final RegExp _rxShortcode = RegExp(r'^[a-zA-Z0-9_]+$');

final RegExp _rxUrl = RegExp(r'^https?://', caseSensitive: false);

/// One NIP-30 emoji pack (kind 30030).
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

  /// (shortcode, url) entries, at most 120.
  final List<({String shortcode, String url})> emojis;

  String get key => '$pubkey:$identifier';
}

class CustomEmojiState {
  const CustomEmojiState({
    this.codeToUrl = const {},
    this.packs = const [],
  });

  /// shortcode -> original (un-proxied) image url.
  final Map<String, String> codeToUrl;

  /// Loaded packs, deduped by [CustomEmojiPack.key].
  final List<CustomEmojiPack> packs;

  bool get isEmpty => codeToUrl.isEmpty;

  static const empty = CustomEmojiState();
}

/// Loads cached emoji, requiring a valid shortcode and http(s) url and never shadowing built-in shortcodes.
CustomEmojiState loadCustomEmojiState(SharedPreferences prefs) {
  final codeToUrl = <String, String>{};

  void register(String? shortcode, String? url) {
    if (shortcode == null || url == null) return;
    if (!_rxShortcode.hasMatch(shortcode) || !_rxUrl.hasMatch(url)) return;
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return;
    codeToUrl[shortcode] = url;
  }

  // Array of [shortcode, url] pairs.
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
            // Title kept verbatim; the 'Emoji pack' fallback is applied at render time.
            title: (p['title'] as String?) ?? '',
            createdAt: (p['created_at'] as num?)?.toInt() ?? 0,
            emojis: emojis,
          ));
        }
      }
    } catch (_) {}
  }

  // Newest first; approximates the PWA order without live ownership info.
  packs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return CustomEmojiState(codeToUrl: codeToUrl, packs: packs);
}

/// Proxied emoji image URL, or [url] verbatim when no proxy base is configured.
String proxiedEmojiUrl(String url, String? proxyBase) {
  if (ApiConfig.directMedia || proxyBase == null || proxyBase.isEmpty) return url;
  return '$proxyBase?emoji=1&url=${Uri.encodeQueryComponent(url)}';
}

/// Overridden where the picker mounts and in tests; empty by default so nothing reads prefs at import.
final customEmojiStateProvider = Provider<CustomEmojiState>(
  (ref) => CustomEmojiState.empty,
);

/// Resolved lazily so the stores build only when a picker opens.
final emojiPrefsProvider = FutureProvider<SharedPreferences>(
  (ref) => ref.watch(sharedPrefsProvider.future),
);

// Custom-emoji image prefetch (emoji.js `_prefetchCustomEmojiImages` /
// `_runEmojiPrefetch`, lines 52-97): shortly after launch — and again whenever
// new emoji/packs arrive — warm the images the user is most likely to see
// first (recent emojis, then favorited/own/subscribed pack emojis), up to 60
// per run, skipped entirely in low-data mode. Everything else keeps loading
// lazily on first render.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import 'custom_emoji.dart';
import 'emoji_data.dart';

/// Whole-string `:shortcode:` (emoji.js:70 `^:([a-zA-Z0-9_]+):$`).
final RegExp _rxWholeToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

/// Pending debounce timer (`this._emojiPrefetchTimer`).
Timer? _prefetchTimer;

/// Raw (un-proxied) urls already warmed this run of the app
/// (`this._prefetchedEmojiUrls`).
final Set<String> _prefetchedUrls = <String>{};

bool _kickedOff = false;

/// Build-time entry point: schedules the first prefetch once per app run (the
/// PWA's first `registerCustomEmoji`/`_storeEmojiPack` after the cache
/// hydrates does the same). Later arrivals re-schedule via
/// [scheduleCustomEmojiPrefetch] from a `liveCustomEmojiProvider` listener.
void kickCustomEmojiPrefetch(ProviderContainer container) {
  if (_kickedOff) return;
  _kickedOff = true;
  scheduleCustomEmojiPrefetch(container);
}

/// `_prefetchCustomEmojiImages` (emoji.js:52-61): no-op while a run is already
/// pending or in low-data mode; otherwise defer the run by 3s (+ idle — the
/// deferred [Timer] is the closest Flutter analogue of
/// `setTimeout(3000)` + `requestIdleCallback`).
void scheduleCustomEmojiPrefetch(ProviderContainer container) {
  if (_prefetchTimer != null) return;
  if (container.read(settingsProvider).lowDataMode) return;
  _prefetchTimer = Timer(const Duration(seconds: 3), () {
    _prefetchTimer = null;
    _runEmojiPrefetch(container);
  });
}

/// `_runEmojiPrefetch` (emoji.js:64-97): collect candidate urls — recents
/// first, then every emoji of each favorited/own/subscribed pack — and warm up
/// to 60 not-yet-prefetched images. The PWA fires all of its `img.src` warms
/// at once into the browser's HTTP cache; Flutter's warms go through
/// [InlineNetworkImage.prefetch] SEQUENTIALLY so 60 downloads don't storm the
/// flutter_cache_manager sqflite DB.
Future<void> _runEmojiPrefetch(ProviderContainer container) async {
  final custom = container.read(liveCustomEmojiProvider);
  if (custom.codeToUrl.isEmpty) return;

  final urls = <String>[];

  // Recents first (emoji.js:69-72): only exact `:code:` tokens that resolve to
  // a known custom emoji. Read the persisted store directly — like the PWA's
  // startup-hydrated `this.recentEmojis` — so the run doesn't depend on the
  // recents provider having been hydrated by an opened picker yet.
  try {
    final prefs = await container.read(emojiPrefsProvider.future);
    for (final e in EmojiRecentsStore(prefs).load()) {
      final m = _rxWholeToken.firstMatch(e);
      final url = m == null ? null : custom.codeToUrl[m.group(1)];
      if (url != null) urls.add(url);
    }

    // Then favorited/own/subscribed packs (emoji.js:73-81). Fav = starred in
    // `nym_emoji_pack_favorites`; own = authored by the self pubkey;
    // subscribed = referenced by the user's kind-10030 list.
    final favSet =
        EmojiFavoritesStore(prefs, kEmojiPackFavoritesKey).load().toSet();
    final selfPubkey = container.read(nostrControllerProvider).identity?.pubkey;
    final liveNotifier = container.read(liveCustomEmojiProvider.notifier);
    for (final pack in custom.packs) {
      final isOwn = selfPubkey != null && pack.pubkey == selfPubkey;
      if (!favSet.contains(pack.key) &&
          !isOwn &&
          !liveNotifier.isPackSubscribed(pack)) {
        continue;
      }
      for (final e in pack.emojis) {
        final url = custom.codeToUrl[e.shortcode];
        if (url != null) urls.add(url);
      }
    }
  } catch (_) {
    // Prefs unavailable — prefetch is best-effort only.
    return;
  }

  // Budget of 60 NEW urls per run (emoji.js:82-95), dedup'd across runs on the
  // raw url; fetched through the same emoji proxy the render path uses
  // (`getProxiedEmojiUrl`).
  var budget = 60;
  for (final url in urls) {
    if (budget <= 0) break;
    if (!_prefetchedUrls.add(url)) continue;
    budget--;
    await InlineNetworkImage.prefetch(proxiedMedia(url, emoji: true));
  }
}

// Warms up to 60 likely-seen custom emoji images after launch and on new packs; skipped in low-data mode.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import 'custom_emoji.dart';
import 'emoji_data.dart';

final RegExp _rxWholeToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

Timer? _prefetchTimer;

/// Raw (un-proxied) urls already warmed this app run.
final Set<String> _prefetchedUrls = <String>{};

bool _kickedOff = false;

/// Test-only: cancels the pending timer so widget tests don't trip over it at teardown.
@visibleForTesting
void resetCustomEmojiPrefetchForTest() {
  _prefetchTimer?.cancel();
  _prefetchTimer = null;
  _kickedOff = false;
}

/// Schedules the first prefetch once per app run; later arrivals reschedule via [scheduleCustomEmojiPrefetch].
void kickCustomEmojiPrefetch(ProviderContainer container) {
  if (_kickedOff) return;
  _kickedOff = true;
  scheduleCustomEmojiPrefetch(container);
}

/// No-op while pending or in low-data mode; otherwise runs after 3s.
void scheduleCustomEmojiPrefetch(ProviderContainer container) {
  if (_prefetchTimer != null) return;
  if (container.read(settingsProvider).lowDataMode) return;
  _prefetchTimer = Timer(const Duration(seconds: 3), () {
    _prefetchTimer = null;
    _runEmojiPrefetch(container);
  });
}

/// Warms recents, then favorited/own/subscribed pack emojis, sequentially so downloads don't storm the cache DB.
Future<void> _runEmojiPrefetch(ProviderContainer container) async {
  final custom = container.read(liveCustomEmojiProvider);
  if (custom.codeToUrl.isEmpty) return;

  final urls = <String>[];

  // Read the persisted recents directly so this doesn't depend on the picker having hydrated them.
  try {
    final prefs = await container.read(emojiPrefsProvider.future);
    for (final e in EmojiRecentsStore(prefs).load()) {
      final m = _rxWholeToken.firstMatch(e);
      final url = m == null ? null : custom.codeToUrl[m.group(1)];
      if (url != null) urls.add(url);
    }

    // Fav = starred packs; own = self-authored; subscribed = in the user's kind-10030 list.
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
    // Prefs unavailable; prefetch is best-effort.
    return;
  }

  // At most 60 new urls per run, deduped across runs on the raw url.
  var budget = 60;
  for (final url in urls) {
    if (budget <= 0) break;
    if (!_prefetchedUrls.add(url)) continue;
    budget--;
    await InlineNetworkImage.prefetch(proxiedMedia(url, emoji: true));
  }
}

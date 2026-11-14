import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_provider.dart';
import '../emoji/custom_emoji.dart' show emojiPrefsProvider;
import '../emoji/emoji_data.dart';
import '../emoji/gif_picker.dart';
import '../translate/translate_languages.dart' show kTranslateFavoritesKey;

class SyncedStores {
  SyncedStores(this.prefs, this._changed);

  final SharedPreferences prefs;
  final void Function() _changed;

  static const List<String> keys = [
    kEmojiCategoryFavoritesKey,
    kEmojiPackFavoritesKey,
    kTranslateFavoritesKey,
    kFavoriteGifsKey,
    kRecentEmojisKey,
  ];

  late final EmojiFavoritesStore emojiCategories =
      EmojiFavoritesStore(prefs, kEmojiCategoryFavoritesKey, onChanged: _changed);
  late final EmojiFavoritesStore emojiPacks =
      EmojiFavoritesStore(prefs, kEmojiPackFavoritesKey, onChanged: _changed);
  late final EmojiFavoritesStore translateLanguages =
      EmojiFavoritesStore(prefs, kTranslateFavoritesKey, onChanged: _changed);
  late final FavoriteGifsStore gifs = FavoriteGifsStore(prefs, onChanged: _changed);
  late final EmojiRecentsStore recents =
      EmojiRecentsStore(prefs, onChanged: _changed);
}

final syncedStoresProvider = FutureProvider<SyncedStores>((ref) async {
  final prefs = await ref.watch(emojiPrefsProvider.future);
  return SyncedStores(
      prefs, () => ref.read(settingsProvider.notifier).notifySyncedChange());
});

final syncedStoresRevisionProvider = StateProvider<int>((ref) => 0);

final columnsLayoutRevisionProvider = StateProvider<int>((ref) => 0);

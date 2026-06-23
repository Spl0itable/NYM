// GIF picker — 1:1 port of the PWA's composer `#gifPicker .gif-picker`
// surface (ui-context.js `showGifPicker`/`displayGifs`, lines 2003-2167;
// markup index.html:792; styles styles-features.css:1562-1717).
//
// Layout: header (search input), 2-column grid of GIFs, "Powered by GIPHY"
// attribution. Trending loads on open; typing (debounced 500ms, ui-context.js
// :2045) switches to search; clearing returns to trending. Favorites
// (`nym_favorite_gifs`, ≤100) show as a "Favorites" section above trending,
// each GIF has a star toggle (ui-context.js `toggleFavoriteGif`). Selecting a
// GIF inserts its URL into the composer (ui-context.js `insertGif`).

import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/api/api_client.dart';

/// Giphy API key — same key the PWA uses (`this.giphyApiKey`, app.js:679).
/// Requests are routed through the backend `/api/proxy?action=giphy` worker
/// (the proxy attaches the key + `limit=20&rating=g` upstream), so the user's
/// IP is never exposed to Giphy — matching the PWA.
const String kGiphyApiKey = kApiGiphyApiKey;

/// localStorage key for favorite GIFs (ui-context.js:2091), ≤100.
const String kFavoriteGifsKey = 'nym_favorite_gifs';
const int kFavoriteGifsCap = 100;

/// One GIF result: the `fixed_height` image url + title (ui-context.js:2154).
class GifItem {
  const GifItem({required this.url, required this.title});
  final String url;
  final String title;

  Map<String, Object> toJson() => {'url': url, 'title': title};
}

/// Giphy client routed through the backend proxy. Trending + search go to
/// `/api/proxy?action=giphy` (relays.js `fetchGiphy`, lines 3221-3238); the
/// proxy returns the same Giphy JSON shape (`{data:[{images:{fixed_height:
/// {url}}, title}]}`) so parsing is identical to the direct path. The
/// [ApiClient] is injectable for tests (mock `http.Client`).
class GiphyService {
  GiphyService({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  Future<List<GifItem>> trending() => _parse(_api.giphyTrending());

  Future<List<GifItem>> search(String query) => _parse(_api.giphySearch(query));

  Future<List<GifItem>> _parse(Future<Map<String, dynamic>> req) async {
    final body = await req;
    final data = body['data'];
    if (data is! List) return const [];
    final out = <GifItem>[];
    for (final g in data) {
      if (g is! Map) continue;
      // images.fixed_height.url (ui-context.js:2154).
      final images = g['images'];
      final fixed = images is Map ? images['fixed_height'] : null;
      final url = fixed is Map ? fixed['url'] : null;
      if (url is! String || url.isEmpty) continue;
      out.add(GifItem(url: url, title: (g['title'] as String?) ?? ''));
    }
    return out;
  }
}

/// Provider for the Giphy client (overridable in tests; network is only ever
/// touched when the picker is actually mounted).
final giphyServiceProvider = Provider<GiphyService>((ref) => GiphyService());

/// Favorites store, persisted under [kFavoriteGifsKey] as a JSON array of
/// `{url,title}` (ui-context.js `_getFavoriteGifs`/`saveFavoriteGifs`).
class FavoriteGifsStore {
  FavoriteGifsStore(this._prefs);
  final SharedPreferences _prefs;

  List<GifItem> load() {
    final raw = _prefs.getString(kFavoriteGifsKey);
    if (raw == null || raw.isEmpty) return <GifItem>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .where((g) => g['url'] is String)
            .map((g) => GifItem(
                  url: g['url'] as String,
                  title: g['title'] is String ? g['title'] as String : '',
                ))
            .toList();
      }
    } catch (_) {}
    return <GifItem>[];
  }

  /// Toggle favorite for [url] (ui-context.js `toggleFavoriteGif`): remove if
  /// present, else prepend; cap at 100. Returns the new list.
  Future<List<GifItem>> toggle(String url, String title) async {
    final favs = load();
    final idx = favs.indexWhere((g) => g.url == url);
    if (idx >= 0) {
      favs.removeAt(idx);
    } else {
      favs.insert(0, GifItem(url: url, title: title));
    }
    final capped = favs.take(kFavoriteGifsCap).toList();
    await _prefs.setString(
      kFavoriteGifsKey,
      jsonEncode(capped.map((g) => g.toJson()).toList()),
    );
    return capped;
  }
}

/// The GIF picker panel. [favoritesStore] persists favorites; [onSelect]
/// receives the chosen GIF url to insert into the composer.
class GifPicker extends ConsumerStatefulWidget {
  const GifPicker({
    super.key,
    required this.favoritesStore,
    required this.onSelect,
    this.proxyBase,
  });

  final FavoriteGifsStore favoritesStore;
  final ValueChanged<String> onSelect;

  /// Optional media proxy base (unused on native — GIFs load directly).
  final String? proxyBase;

  @override
  ConsumerState<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends ConsumerState<GifPicker> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  List<GifItem> _favorites = const [];
  List<GifItem> _gifs = const [];
  bool _loading = true;
  bool _error = false;
  bool _showFavorites = true; // favorites only shown in trending view

  @override
  void initState() {
    super.initState();
    _favorites = widget.favoritesStore.load();
    // Lazy: network only fires here, once the picker is mounted.
    _loadTrending();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTrending() async {
    setState(() {
      _loading = true;
      _error = false;
      _showFavorites = true;
    });
    try {
      final gifs = await ref.read(giphyServiceProvider).trending();
      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // On failure, still show favorites if any (ui-context.js:2063).
        _error = _favorites.isEmpty;
        _gifs = const [];
      });
    }
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _loading = true;
      _error = false;
      _showFavorites = false;
    });
    try {
      final gifs = await ref.read(giphyServiceProvider).search(query);
      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _loading = false;
        _error = gifs.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _gifs = const [];
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      _loadTrending();
      return;
    }
    // 500ms debounce (ui-context.js:2045).
    _debounce = Timer(const Duration(milliseconds: 500), () => _runSearch(q));
  }

  Future<void> _toggleFavorite(GifItem gif) async {
    final next = await widget.favoritesStore.toggle(gif.url, gif.title);
    if (!mounted) return;
    setState(() => _favorites = next);
  }

  bool _isFavorite(String url) => _favorites.any((g) => g.url == url);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      // .gif-picker: 350 wide, max 450 tall, glass, radius md, padding 12.
      constraints: const BoxConstraints(maxWidth: 350, maxHeight: 450),
      width: 350,
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border.all(color: c.glassBorder),
        borderRadius: NymRadius.rmd,
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c),
          const SizedBox(height: 10),
          Flexible(child: _results(c)),
          _attribution(c),
        ],
      ),
    );
  }

  /// `.gif-modal-header` + `.gif-search-input` (styles-features.css:1582-1608).
  Widget _header(NymColors c) {
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      style: TextStyle(color: c.textBright, fontSize: 12),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search GIFs...',
        hintStyle: TextStyle(color: c.textDim, fontSize: 12),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.primaryA(0.3)),
        ),
      ),
    );
  }

  Widget _results(NymColors c) {
    if (_loading) {
      return _centered(c, 'Loading GIFs...', isError: false);
    }
    final showFavs = _showFavorites && _favorites.isNotEmpty;
    if (_error && !showFavs) {
      return _centered(
        c,
        _showFavorites ? 'Failed to load GIFs' : 'No GIFs found',
        isError: true,
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showFavs) ...[
            _sectionLabel(c, 'Favorites'),
            _grid(_favorites),
            if (_gifs.isNotEmpty) _sectionLabel(c, 'Trending'),
          ],
          _grid(_gifs),
        ],
      ),
    );
  }

  /// `.gif-section-label` (styles-features.css:1674).
  Widget _sectionLabel(NymColors c, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: c.textDim,
        ),
      ),
    );
  }

  /// `.gif-grid`: 2 columns, gap 8, square items (styles-features.css:1610).
  Widget _grid(List<GifItem> gifs) {
    if (gifs.isEmpty) return const SizedBox.shrink();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [for (final g in gifs) _gifTile(g)],
    );
  }

  /// `.gif-item` with image + `.gif-fav-btn` star (styles-features.css:1616).
  Widget _gifTile(GifItem gif) {
    final c = context.nym;
    final fav = _isFavorite(gif.url);
    return InkWell(
      onTap: () => widget.onSelect(gif.url),
      borderRadius: NymRadius.rsm,
      child: ClipRRect(
        borderRadius: NymRadius.rsm,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                border: Border.all(color: Colors.transparent, width: 2),
                borderRadius: NymRadius.rsm,
              ),
              child: CachedNetworkImage(
                imageUrl: gif.url,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) =>
                    Icon(Icons.broken_image, size: 18, color: c.textDim),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: const Color(0x73000000),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _toggleFavorite(gif),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: Icon(
                      fav ? Icons.star : Icons.star_border,
                      size: 14,
                      color: fav ? c.warning : Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.gif-attribution` (styles-features.css:1701).
  Widget _attribution(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.glassBorder)),
        ),
        child: Text.rich(
          TextSpan(
            text: 'Powered by ',
            style: TextStyle(color: c.textDim, fontSize: 10),
            children: [
              TextSpan(text: 'GIPHY', style: TextStyle(color: c.primary)),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _centered(NymColors c, String text, {required bool isError}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isError ? c.danger : c.textDim,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

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
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/api/api_client.dart';
import '../../state/settings_provider.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import 'modal_close_chip.dart';

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
    this.onClose,
    this.proxyBase,
  });

  final FavoriteGifsStore favoritesStore;
  final ValueChanged<String> onSelect;

  /// Dismisses the picker (`.gif-modal-close` ✕). When null the ✕ falls back to
  /// `Navigator.maybePop` (dialog usage).
  final VoidCallback? onClose;

  /// Optional media proxy base (unused on native — GIFs load directly).
  final String? proxyBase;

  @override
  ConsumerState<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends ConsumerState<GifPicker>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;

  List<GifItem> _favorites = const [];
  List<GifItem> _gifs = const [];
  bool _loading = true;
  bool _error = false;
  bool _showFavorites = true; // favorites only shown in trending view
  bool _searchMode = false; // false = trending, true = active search
  bool _searchFailed = false; // search errored (vs empty result set)

  @override
  void initState() {
    super.initState();
    // The panel lifts above the keyboard by reading View.viewInsets (see
    // build); that read establishes no rebuild dependency, so observe metrics
    // changes to repaint as the keyboard animates in/out.
    WidgetsBinding.instance.addObserver(this);
    _favorites = widget.favoritesStore.load();
    // Rebuild on focus to apply the `.gif-search-input:focus` fill + glow ring.
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    // Lazy: network only fires here, once the picker is mounted.
    _loadTrending();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTrending() async {
    setState(() {
      _loading = true;
      _error = false;
      _showFavorites = true;
      _searchMode = false;
      _searchFailed = false;
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
      _searchMode = true;
      _searchFailed = false;
    });
    try {
      final gifs = await ref.read(giphyServiceProvider).search(query);
      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _loading = false;
        _error = gifs.isEmpty; // empty result → "No GIFs found"
        _searchFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _searchFailed = true; // network error → "Failed to search GIFs"
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
    final transparency =
        ref.watch(settingsProvider.select((s) => s.transparencyEnabled));
    // Keyboard-aware, like the PWA riding the visual viewport: overlay hosts
    // anchor the panel to the SCREEN bottom, so the panel itself pads up by
    // the keyboard height and shrinks to the space left above it — keeping
    // the search field + results visible while typing. We read the inset from
    // the raw FlutterView rather than MediaQuery: inside an OverlayPortal that
    // sits under a resizing Scaffold, MediaQuery.viewInsets is already
    // consumed (reports 0), so the panel would never lift. View.viewInsets is
    // in physical px and is never consumed by an ancestor.
    final view = View.of(context);
    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    final maxPanelHeight = keyboardInset > 0
        // Screen minus keyboard, status bar, and the 60px bottom-bar offset
        // the phone popover anchors at (+8 breathing room).
        ? (MediaQuery.sizeOf(context).height -
                keyboardInset -
                MediaQuery.paddingOf(context).top -
                68)
            .clamp(160.0, 450.0)
            .toDouble()
        : 450.0;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        // .gif-picker: 350 wide, max 450 tall, glass, radius md, padding 12.
        constraints: BoxConstraints(maxWidth: 350, maxHeight: maxPanelHeight),
        width: 350,
        decoration: BoxDecoration(
          // `.gif-picker` bg: with Transparency ON (no `solid-ui` body class) the
          // PWA hardcodes rgba(20,20,35,0.9) dark (styles-features.css:1565) /
          // rgba(255,255,255,0.92) light (styles-themes-responsive.css:1173-1177);
          // with Transparency OFF (`solid-ui`, the default) it's the opaque
          // `var(--glass-bg)` (#14141e dark / #ffffff light,
          // styles-themes-responsive.css:1583-1600) — exactly `c.glassBg`.
          color: transparency
              ? (c.isLight
                  ? const Color(0xEBFFFFFF) // rgba(255,255,255,0.92)
                  : const Color(0xE6141423)) // rgba(20,20,35,0.9)
              : c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
          // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5); light mode redefines it to
          // rgba(0,0,0,0.12) (styles-themes-responsive.css:537, and explicitly on
          // `body.light-mode .gif-picker` at :1173-1177).
          boxShadow: [
            BoxShadow(
              color:
                  c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
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
      ),
    );
  }

  /// `.gif-modal-header` (search input + close ✕, bottom-divider, gap 10) +
  /// `.gif-search-input` (styles-features.css:1582-1608). On focus the input
  /// fills `white@0.07`, border → primary@0.3, with a 3px primary@0.06 glow.
  Widget _header(NymColors c) {
    final focused = _searchFocus.hasFocus;
    final field = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rxs,
        boxShadow: focused
            ? [
                BoxShadow(
                    color: c.primaryA(0.06), blurRadius: 0, spreadRadius: 3),
              ]
            : null,
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        onChanged: _onSearchChanged,
        // `color: var(--text-bright)`; light mode overrides it to `var(--text)`
        // (`body.light-mode .gif-search-input { color: var(--text) !important }`,
        // styles-themes-responsive.css:1063-1068 — more specific than the
        // generic `body.light-mode input { color: #000000 !important }`).
        style:
            TextStyle(color: c.isLight ? c.text : c.textBright, fontSize: 12),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('Search GIFs...'),
          hintStyle: TextStyle(color: c.textDim, fontSize: 12),
          filled: true,
          fillColor: focused
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.white.withValues(alpha: 0.05),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
      ),
    );
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: field),
          const SizedBox(width: 10),
          // `.modal-close.gif-modal-close` ✕ chip.
          ModalCloseChip(
            onTap: widget.onClose ?? () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _results(NymColors c) {
    if (_loading) {
      // Per-mode loading copy: trending → "Loading trending GIFs..."
      // (ui-context.js:2056); search → "Searching GIFs..." (:2073).
      return _centered(
        c,
        _searchMode ? tr('Searching GIFs...') : tr('Loading trending GIFs...'),
        isError: false,
      );
    }
    final showFavs = _showFavorites && _favorites.isNotEmpty;
    if (_error && !showFavs) {
      // Trending fail → "Failed to load GIFs" (:2066); search empty → "No GIFs
      // found" (:2079); search FAIL → "Failed to search GIFs" (:2084).
      final msg = _searchMode
          ? (_searchFailed ? tr('Failed to search GIFs') : tr('No GIFs found'))
          : tr('Failed to load GIFs');
      return _centered(c, msg, isError: true);
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showFavs) ...[
            _sectionLabel(c, tr('Favorites')),
            _grid(_favorites),
            if (_gifs.isNotEmpty) _sectionLabel(c, tr('Trending')),
          ],
          _grid(_gifs),
        ],
      ),
    );
  }

  /// `.gif-section-label` (styles-features.css:1674-1683): 10/w700/upper/
  /// ls0.06em/text-dim/opacity 0.8/padding 4px 2px 0.
  Widget _sectionLabel(NymColors c, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: c.textDim.withValues(alpha: 0.8),
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
      // Without an explicit padding, GridView absorbs the ambient
      // MediaQuery.padding (the status-bar inset inside the overlay) as its
      // default sliver padding — a phantom empty band above the GIFs. The
      // PWA's `.gif-grid` has no padding.
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [for (final g in gifs) _gifTile(g)],
    );
  }

  /// `.gif-item` with image + `.gif-fav-btn` star (styles-features.css:1616).
  Widget _gifTile(GifItem gif) {
    return _GifTile(
      gif: gif,
      favorite: _isFavorite(gif.url),
      onSelect: () => widget.onSelect(gif.url),
      onToggleFavorite: () => _toggleFavorite(gif),
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
            text: tr('Powered by '),
            style: TextStyle(color: c.textDim, fontSize: 10),
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      final uri = Uri.parse('https://giphy.com');
                      launchUrl(uri, mode: LaunchMode.externalApplication);
                    },
                    child: Text('GIPHY',
                        style: TextStyle(color: c.primary, fontSize: 10)),
                  ),
                ),
              ),
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

/// `.gif-item`: a square thumbnail with a `.gif-fav-btn` star. On hover the
/// border goes primary@0.3, a `--shadow-md` (0 4px 16px rgba(0,0,0,0.4)) lifts
/// it, and it scales to 1.03 (styles-features.css:1616-1638).
class _GifTile extends StatefulWidget {
  const _GifTile({
    required this.gif,
    required this.favorite,
    required this.onSelect,
    required this.onToggleFavorite,
  });

  final GifItem gif;
  final bool favorite;
  final VoidCallback onSelect;
  final VoidCallback onToggleFavorite;

  @override
  State<_GifTile> createState() => _GifTileState();
}

class _GifTileState extends State<_GifTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // `.gif-item { transition: all var(--transition) }` — 0.25s
      // cubic-bezier(0.4,0,0.2,1) (styles-core.css:95), which is exactly
      // Flutter's [Curves.fastOutSlowIn].
      child: AnimatedScale(
        scale: _hover ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.fastOutSlowIn,
          decoration: BoxDecoration(
            // `.gif-item`: 2px transparent border (→ primary@0.3 on hover).
            border: Border.all(
                color: _hover ? c.primaryA(0.3) : Colors.transparent, width: 2),
            borderRadius: NymRadius.rsm,
            boxShadow: _hover
                ? const [
                    // `--shadow-md`: 0 4px 16px rgba(0,0,0,0.4).
                    BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 16,
                        offset: Offset(0, 4)),
                  ]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: NymRadius.rsm,
            child: InkWell(
              onTap: widget.onSelect,
              borderRadius: NymRadius.rsm,
              child: ClipRRect(
                borderRadius: NymRadius.rsm,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: Colors.white.withValues(alpha: 0.03),
                      child: CachedNetworkImage(
                        // Route Giphy GIFs through the media proxy so the user's
                        // IP is never exposed to the CDN (PWA getProxiedMediaUrl).
                        imageUrl: proxiedMedia(widget.gif.url),
                        fit: BoxFit.cover,
                        placeholder: (_, __) => const SizedBox.shrink(),
                        errorWidget: (_, __, ___) => Icon(Icons.broken_image,
                            size: 18, color: c.textDim),
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
                          onTap: widget.onToggleFavorite,
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            // `.gif-fav-btn` (ui-context.js:2133) — the custom
                            // 5-point star: outline by default, filled gold
                            // (`--warning`) when `.active`.
                            child: Center(
                              child: NymSvgIcon(
                                widget.favorite
                                    ? NymIcons.starFilled
                                    : NymIcons.starOutline,
                                size: 14,
                                color: widget.favorite
                                    ? c.warning
                                    : Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

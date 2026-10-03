// GIF picker: trending on open, 500ms-debounced search, starred favorites, and selection inserts the GIF URL.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../messages/pausable_animated_image.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/api/api_client.dart';
import '../../state/settings_provider.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import 'modal_close_chip.dart';

/// Requests go through the backend proxy, which attaches the key, so the user's IP never reaches Giphy.
const String kGiphyApiKey = kApiGiphyApiKey;

/// Favorite GIFs storage key (max 100).
const String kFavoriteGifsKey = 'nym_favorite_gifs';
const int kFavoriteGifsCap = 100;

/// One GIF result: the `fixed_height` image url and title.
class GifItem {
  const GifItem({required this.url, required this.title});
  final String url;
  final String title;

  Map<String, Object> toJson() => {'url': url, 'title': title};
}

/// Giphy client via the backend proxy, which returns Giphy's JSON shape unchanged.
class GiphyService {
  GiphyService({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  Future<List<GifItem>> trending() => _parse(_api.giphyTrending());

  Future<List<GifItem>> search(String query) => _parse(_api.giphySearch(query));

  Future<Uint8List?> bytes(String url) async {
    try {
      final res = await http.get(Uri.parse(proxiedMedia(url)));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  Future<List<GifItem>> _parse(Future<Map<String, dynamic>> req) async {
    final body = await req;
    final data = body['data'];
    if (data is! List) return const [];
    final out = <GifItem>[];
    for (final g in data) {
      if (g is! Map) continue;
      final images = g['images'];
      final fixed = images is Map ? images['fixed_height'] : null;
      final url = fixed is Map ? fixed['url'] : null;
      if (url is! String || url.isEmpty) continue;
      out.add(GifItem(url: url, title: (g['title'] as String?) ?? ''));
    }
    return out;
  }
}

/// Overridable in tests; network is only touched once the picker mounts.
final giphyServiceProvider = Provider<GiphyService>((ref) => GiphyService());

/// Favorites persisted as a JSON array of `{url,title}`.
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

  /// Removes [url] if present, else prepends; capped at 100.
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

class GifPicker extends ConsumerStatefulWidget {
  const GifPicker({
    super.key,
    required this.favoritesStore,
    required this.onSelect,
    this.onClose,
    this.proxyBase,
    this.tabs,
  });

  final Widget? tabs;

  final FavoriteGifsStore favoritesStore;
  final ValueChanged<GifItem> onSelect;

  /// When null, close falls back to `Navigator.maybePop`.
  final VoidCallback? onClose;

  /// Optional media proxy base; unused on native.
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
    // `View.viewInsets` sets up no rebuild dependency, so observe metrics to follow the keyboard.
    WidgetsBinding.instance.addObserver(this);
    _favorites = widget.favoritesStore.load();
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    // Lazy: network fires only once the picker mounts.
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
        // On failure, still show favorites if any.
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
    // Pad up by the keyboard via raw `View.viewInsets`; MediaQuery's insets are already consumed under a resizing Scaffold.
    final view = View.of(context);
    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    final maxPanelHeight = keyboardInset > 0
        // Screen minus keyboard, status bar and the 60px bottom-bar anchor (+8).
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
        constraints: BoxConstraints(maxWidth: 350, maxHeight: maxPanelHeight),
        width: 350,
        decoration: BoxDecoration(
          // Transparency on uses fixed translucent fills; solid-ui (default) is the opaque glass background.
          color: transparency
              ? (c.isLight
                  ? const Color(0xEBFFFFFF)
                  : const Color(0xE6141423))
              : c.glassBg,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
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
            ?widget.tabs,
            _header(c),
            const SizedBox(height: 10),
            Flexible(child: _results(c)),
            _attribution(c),
          ],
        ),
      ),
    );
  }

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
        // Light mode overrides the text color to `--text`.
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
          ModalCloseChip(
            onTap: widget.onClose ?? () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _results(NymColors c) {
    if (_loading) {
      return _centered(
        c,
        _searchMode ? tr('Searching GIFs...') : tr('Loading trending GIFs...'),
        isError: false,
      );
    }
    final showFavs = _showFavorites && _favorites.isNotEmpty;
    if (_error && !showFavs) {
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

  Widget _grid(List<GifItem> gifs) {
    if (gifs.isEmpty) return const SizedBox.shrink();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // Explicit zero padding, or GridView absorbs the status-bar inset as a phantom band.
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [for (final g in gifs) _gifTile(g)],
    );
  }

  Widget _gifTile(GifItem gif) {
    return _GifTile(
      gif: gif,
      favorite: _isFavorite(gif.url),
      onSelect: () => widget.onSelect(gif),
      onToggleFavorite: () => _toggleFavorite(gif),
    );
  }

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

/// Square thumbnail with a favorite star; hover lifts, outlines and scales it to 1.03.
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
      // CSS `--transition` is exactly [Curves.fastOutSlowIn].
      child: AnimatedScale(
        scale: _hover ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.fastOutSlowIn,
          decoration: BoxDecoration(
            border: Border.all(
                color: _hover ? c.primaryA(0.3) : Colors.transparent, width: 2),
            borderRadius: NymRadius.rsm,
            boxShadow: _hover
                ? const [
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
                      child: PausableAnimatedImage(
                        // Proxied so the user's IP never reaches the CDN; decode is capped to the cell and playback pauses offscreen.
                        image: CachedNetworkImageProvider(
                          proxiedMedia(widget.gif.url),
                          maxWidth:
                              (240 * MediaQuery.devicePixelRatioOf(context))
                                  .ceil(),
                        ),
                        visibilityKey: ValueKey('gifpick:${widget.gif.url}'),
                        fit: BoxFit.cover,
                        placeholder: const SizedBox.shrink(),
                        errorBuilder: (_) => Icon(Icons.broken_image,
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

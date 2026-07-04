// Emoji picker — 1:1 port of the PWA's composer `#emojiPicker .emoji-picker`
// surface (reactions.js `setupEmojiPicker`, lines 1195-1227; markup
// index.html:791; styles styles-components.css:2090-2171).
//
// Layout (top → bottom), matching `_emojiSectionsHtml` (emoji.js lines 534-557):
//   - sticky search box (`.emoji-picker-search`)
//   - "Recently Used" section (when recents exist)
//   - custom NIP-30 pack sections (rendered as network images)
//   - default categories in `kEmojiCategoryOrder`, titles capitalized
// Grid: 6 columns (styles-components.css:2152); 5 columns at width ≤480px
// (styles-themes-responsive.css:436-439). Search filters by emoji char or any
// of its shortcode names (emoji.js `_applyEmojiSearch`, lines 789-804).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/nym_icons.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import 'custom_emoji.dart';
import 'emoji_data.dart';
import 'modal_close_chip.dart';

/// Width breakpoint below which the grid drops to 5 columns
/// (styles-themes-responsive.css:428 `max-width: 480px`).
const double _kFiveColMaxWidth = 480;

/// A picker panel. [recents] is the current most-recent-first list; selecting
/// an emoji calls [onSelect] with the literal char (unicode) or `:code:`
/// (custom). The host updates recents and inserts into the composer.
class EmojiPicker extends ConsumerStatefulWidget {
  const EmojiPicker({
    super.key,
    required this.recents,
    required this.onSelect,
    this.onClose,
    this.proxyBase,
  });

  /// Most-recent-first recents (unicode chars and/or `:code:` tokens).
  final List<String> recents;

  /// Called with the chosen emoji (unicode char or `:shortcode:`).
  final ValueChanged<String> onSelect;

  /// Dismisses the picker (`.emoji-modal-close` ✕, reactions.js:710). When
  /// null the ✕ falls back to popping an enclosing modal route (dialog /
  /// bottom-sheet hosts); overlay-portal hosts should pass their `hide`.
  final VoidCallback? onClose;

  /// Optional media/emoji proxy base for custom emoji images.
  final String? proxyBase;

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  String _query = '';

  late final Map<String, List<String>> _emojiToNames = buildEmojiToNames();

  // Favorite-star state (emoji.js `nym_emoji_category_favorites` /
  // `nym_emoji_pack_favorites`). Loaded lazily once prefs resolve; toggling a
  // star reorders that block to the top live and persists.
  EmojiFavoritesStore? _catFavStore;
  EmojiFavoritesStore? _packFavStore;
  List<String> _categoryFavorites = const [];
  List<String> _packFavorites = const [];

  @override
  void initState() {
    super.initState();
    // The panel lifts above the keyboard by reading View.viewInsets (see
    // build); that read establishes no rebuild dependency, so observe metrics
    // changes to repaint as the keyboard animates in/out.
    WidgetsBinding.instance.addObserver(this);
    _loadFavorites();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFavorites() async {
    try {
      final prefs = await ref.read(emojiPrefsProvider.future);
      if (!mounted) return;
      setState(() {
        _catFavStore = EmojiFavoritesStore(prefs, kEmojiCategoryFavoritesKey);
        _packFavStore = EmojiFavoritesStore(prefs, kEmojiPackFavoritesKey);
        _categoryFavorites = _catFavStore!.load();
        _packFavorites = _packFavStore!.load();
      });
    } catch (_) {
      // Favorites are best-effort; an unavailable store leaves stars inactive.
    }
  }

  Future<void> _toggleCategoryFavorite(String category) async {
    final store = _catFavStore;
    if (store == null) return;
    final next = await store.toggle(category);
    if (!mounted) return;
    setState(() => _categoryFavorites = next);
  }

  Future<void> _togglePackFavorite(String packKey) async {
    final store = _packFavStore;
    if (store == null) return;
    final next = await store.toggle(packKey);
    if (!mounted) return;
    setState(() => _packFavorites = next);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  /// Recents filtered to drop custom `:code:` tokens whose pack is no longer
  /// known (emoji.js `_recentEmojisForPicker`, lines 150-159). The PWA caps the
  /// picker recents at 20 on mobile (`innerWidth<=768`) / 24 on desktop.
  List<String> _visibleRecents(CustomEmojiState custom, double width) {
    final cap = width <= 768 ? 20 : kRecentEmojisCap;
    return widget.recents
        .where((e) {
          final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
          if (m == null) return true;
          return custom.codeToUrl.containsKey(m.group(1));
        })
        .take(cap)
        .toList();
  }

  /// True when an emoji passes the current search (emoji.js `_applyEmojiSearch`:
  /// matches the char itself or any of its space-joined names).
  bool _matches(String emoji) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    if (emoji.toLowerCase().contains(q)) return true;
    final names = _emojiToNames[emoji];
    if (names != null) {
      for (final n in names) {
        if (n.contains(q)) return true;
      }
    }
    return false;
  }

  /// Custom emoji match: search against the shortcode (emoji.js sets
  /// `data-names` to the shortcode for custom options).
  bool _matchesCustom(String shortcode) {
    if (_query.isEmpty) return true;
    return shortcode.toLowerCase().contains(_query.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Read the LIVE NIP-30 store (kind-30030 packs + kind-10030 list + inbound
    // `emoji` tags). It hydrates from the persisted cache on launch, so this is
    // a strict superset of the old static `customEmojiStateProvider` and updates
    // live as packs arrive over relays.
    final custom = ref.watch(liveCustomEmojiProvider);
    final transparency =
        ref.watch(settingsProvider.select((s) => s.transparencyEnabled));
    final width = MediaQuery.sizeOf(context).width;
    final columns = width <= _kFiveColMaxWidth ? 5 : 6;

    final sections = <_Section>[];

    // Recently Used.
    final recents = _visibleRecents(custom, width).where((e) {
      final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
      return m == null ? _matches(e) : _matchesCustom(m.group(1)!);
    }).toList();
    if (recents.isNotEmpty) {
      sections.add(_section(
        c,
        title: 'Recently Used',
        children: recents.map((e) {
          final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
          if (m != null) {
            final url = custom.codeToUrl[m.group(1)];
            if (url != null) return _customCell(m.group(1)!, url);
          }
          return _unicodeCell(e);
        }).toList(),
      ));
    }

    // Custom NIP-30 packs ranked fav(0)→own(1)→subscribed(2)→rest(3), then
    // created_at desc (emoji.js `buildCustomEmojiSectionsHtml`:487-495). Own =
    // authored by the self pubkey; subscribed = referenced by the user's
    // kind-10030 list (`isPackSubscribed`). Own/subscribed packs get a ` ★`
    // title suffix.
    final packFavSet = _packFavorites.toSet();
    final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
    final liveNotifier = ref.read(liveCustomEmojiProvider.notifier);
    bool isOwn(CustomEmojiPack p) =>
        selfPubkey != null && p.pubkey == selfPubkey;
    bool isSubscribed(CustomEmojiPack p) => liveNotifier.isPackSubscribed(p);
    int rank(CustomEmojiPack p) => packFavSet.contains(p.key)
        ? 0
        : isOwn(p)
            ? 1
            : (isSubscribed(p) ? 2 : 3);
    final orderedPacks = [...custom.packs]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return b.createdAt.compareTo(a.createdAt);
      });
    // The PWA renders at most 50 pack sections, each sliced to its first 120
    // known emojis (`buildCustomEmojiSectionsHtml`, emoji.js:499-504). The
    // 50-pack budget counts packs with ≥1 KNOWN emoji; the search filter only
    // hides buttons afterwards (`_applyEmojiSearch`), so it doesn't free slots.
    var shownPacks = 0;
    for (final pack in orderedPacks) {
      if (shownPacks >= 50) break;
      final known = <({String shortcode, String url})>[];
      for (final e in pack.emojis) {
        final url = custom.codeToUrl[e.shortcode];
        if (url == null) continue;
        known.add((shortcode: e.shortcode, url: url));
        if (known.length >= 120) break;
      }
      if (known.isEmpty) continue;
      shownPacks++;
      final cells = <Widget>[
        for (final e in known)
          if (_matchesCustom(e.shortcode)) _customCell(e.shortcode, e.url),
      ];
      if (cells.isEmpty) continue;
      final star = (isOwn(pack) || isSubscribed(pack)) ? ' ★' : '';
      // `pack.title || 'Emoji pack'` (emoji.js:507) — an empty/missing cached
      // title still gets a section header.
      final packTitle = pack.title.isEmpty ? 'Emoji pack' : pack.title;
      sections.add(_section(
        c,
        title: '$packTitle$star',
        children: cells,
        isFavorite: packFavSet.contains(pack.key),
        onToggleFavorite:
            _packFavStore == null ? null : () => _togglePackFavorite(pack.key),
      ));
    }

    // Default categories, favorited categories hoisted to the top of the block.
    for (final category in orderedEmojiCategories(_categoryFavorites)) {
      final list = kEmojisByCategory[category]!;
      final cells = <Widget>[
        for (final e in list)
          if (_matches(e)) _unicodeCell(e),
      ];
      if (cells.isEmpty) continue;
      sections.add(_section(
        c,
        title: '${category[0].toUpperCase()}${category.substring(1)}',
        children: cells,
        isFavorite: _categoryFavorites.contains(category),
        onToggleFavorite: _catFavStore == null
            ? null
            : () => _toggleCategoryFavorite(category),
      ));
    }

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
            .clamp(160.0, 400.0)
            .toDouble()
        : 400.0;

    // NOTE: This widget is used inside overlays/portals in a few places.
    // TextField requires a Material ancestor, and Flexible/Expanded require a
    // bounded main-axis constraint. We enforce both here so the picker is safe
    // to mount anywhere.
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: ConstrainedBox(
          // .emoji-picker: max 360×400.
          constraints: BoxConstraints(maxWidth: 360, maxHeight: maxPanelHeight),
          child: LayoutBuilder(builder: (context, constraints) {
            final height = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : maxPanelHeight;
            return Container(
              height: height,
              decoration: BoxDecoration(
                // `.emoji-picker` bg: with Transparency ON (no `solid-ui` body
                // class) the PWA hardcodes rgba(20,20,35,0.9) dark
                // (styles-components.css:2094) / rgba(255,255,255,0.92) light
                // (styles-themes-responsive.css:1167-1171); with Transparency OFF
                // (`solid-ui`, the default) it's the opaque `var(--glass-bg)`
                // (#14141e dark / #ffffff light, styles-themes-responsive.css:
                // 1583-1600) — which is exactly `c.glassBg`.
                color: transparency
                    ? (c.isLight
                        ? const Color(0xEBFFFFFF) // rgba(255,255,255,0.92)
                        : const Color(0xE6141423)) // rgba(20,20,35,0.9)
                    : c.glassBg,
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rmd,
                // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5); light mode redefines
                // it to rgba(0,0,0,0.12) (styles-themes-responsive.css:537, and
                // explicitly on `body.light-mode .emoji-picker` at :1167-1171).
                boxShadow: [
                  BoxShadow(
                    color: c.isLight
                        ? const Color(0x1F000000)
                        : const Color(0x80000000),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(c),
                  // `.emoji-modal-header { margin-bottom: 10px }`.
                  const SizedBox(height: 10),
                  Expanded(
                    child: CustomScrollView(
                      // Lazy: each SliverGrid only mounts the cells in (and just
                      // around) the viewport, so ONLY visible custom-emoji images
                      // fetch + decode — the PWA's `loading="lazy"`. The old
                      // SingleChildScrollView + shrinkWrap GridView mounted EVERY
                      // cell across every pack at once, loading hundreds of images
                      // simultaneously → out-of-memory crash on open.
                      slivers: [
                        for (final s in sections)
                          ..._sectionSlivers(c, s, columns),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  /// `.emoji-modal-header` (styles-components.css:1225-1232): search input +
  /// close ✕ in a row (gap 10), padding-bottom 10, bottom `--glass-border`
  /// divider — matching the PWA's composer emoji modal (reactions.js:708-711).
  Widget _header(NymColors c) {
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: _search(c)),
          const SizedBox(width: 10),
          // `.modal-close.emoji-modal-close` ✕ chip.
          ModalCloseChip(onTap: _handleClose),
        ],
      ),
    );
  }

  /// `.emoji-modal-close` tap (`closeEnhancedEmojiModal`). Prefer the host's
  /// [EmojiPicker.onClose]; dialog/bottom-sheet hosts (settings swipe-react
  /// picker, call overlay) fall back to popping their modal route. Without
  /// either there is nothing to dismiss, so do nothing rather than popping the
  /// hosting screen.
  void _handleClose() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    if (ModalRoute.of(context) != null) {
      Navigator.of(context).maybePop();
    }
  }

  /// `.emoji-picker-search-input` (styles-components.css:2121-2135).
  Widget _search(NymColors c) {
    // Some callers mount the picker inside an OverlayPortal / LookupBoundary.
    // TextField requires a Material ancestor *within the closest*
    // LookupBoundary, so wrap the input itself defensively.
    return Material(
      type: MaterialType.transparency,
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = _sanitizeUserText(v).trim()),
        // `color: var(--text-bright)`; light mode forces this input to #000
        // via `body.light-mode input { color: #000000 !important }`
        // (styles-themes-responsive.css:585-592). Unlike `.emoji-search-input`
        // / `.gif-search-input`, `.emoji-picker-search-input` is NOT in the
        // more specific `color: var(--text) !important` list (:1063-1068), so
        // the generic #000 rule wins here.
        style: TextStyle(
            color: c.isLight ? const Color(0xFF000000) : c.textBright,
            fontSize: 12),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search emoji...',
          hintStyle: TextStyle(color: c.textDim, fontSize: 12),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
            borderSide: BorderSide(color: c.primary),
          ),
        ),
      ),
    );
  }

  /// Defensively sanitize user input to avoid crashes when the platform IME
  /// sends an unpaired surrogate (rare, but can happen on Android).
  static String _sanitizeUserText(String input) {
    final units = input.codeUnits;
    final out = StringBuffer();
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      // High surrogate.
      if (u >= 0xD800 && u <= 0xDBFF) {
        if (i + 1 < units.length) {
          final next = units[i + 1];
          if (next >= 0xDC00 && next <= 0xDFFF) {
            out.writeCharCode(u);
            out.writeCharCode(next);
            i++;
            continue;
          }
        }
        // Unpaired high surrogate -> replacement.
        out.write('\uFFFD');
        continue;
      }
      // Unpaired low surrogate -> replacement.
      if (u >= 0xDC00 && u <= 0xDFFF) {
        out.write('\uFFFD');
        continue;
      }
      out.writeCharCode(u);
    }
    return out.toString();
  }

  /// `.emoji-picker-section` + `.emoji-picker-section-title` (10px uppercase
  /// dim, letter-spacing 1) wrapping a grid (styles-components.css:2137-2154).
  /// [onToggleFavorite]/[isFavorite] add the trailing favorite-star button on
  /// default-category and custom-pack titles (emoji.js:446-451, 510-512).
  _Section _section(NymColors c,
      {required String title,
      required List<Widget> children,
      bool isFavorite = false,
      VoidCallback? onToggleFavorite}) {
    return _Section(
      title: title,
      cells: children,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
    );
  }

  /// `.emoji-btn`: 23px glyph, transparent, hover highlight (here a tap target).
  Widget _unicodeCell(String emoji) {
    return _EmojiCell(
      onTap: () => widget.onSelect(emoji),
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 23, height: 1.1),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// Custom emoji rendered as a 30×30 image (emoji.js `renderCustomEmojiImg`).
  /// Selecting inserts the `:shortcode:` token.
  Widget _customCell(String shortcode, String url) {
    return _EmojiCell(
      onTap: () => widget.onSelect(':$shortcode:'),
      // SVG-aware + decode-safe (same handling as the message body): SVG custom
      // emoji render via flutter_svg, others via the cached raster path, and an
      // undecodable image shows a small broken-image glyph instead of throwing
      // "ImageDecoder unimplemented".
      child: InlineNetworkImage(
        // Always route custom-emoji images through the media proxy so the
        // user's IP is hidden from the host (PWA getProxiedEmojiUrl). When an
        // explicit [proxyBase] is supplied (tests) honor it; otherwise fall
        // back to the shared ApiClient proxy via [proxiedMedia].
        url: (widget.proxyBase != null && widget.proxyBase!.isNotEmpty)
            ? proxiedEmojiUrl(url, widget.proxyBase)
            : proxiedMedia(url, emoji: true),
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        // A gridful of cells would otherwise hammer flutter_cache_manager's
        // sqflite DB (the "database has been locked 0:00:10" flood on open).
        memoryOnly: true,
        // 2 cache-busting retries at 800ms·n, like the PWA's custom-emoji
        // error handler (inline-bindings.js:166-183).
        retryOnError: true,
        placeholder: const SizedBox(width: 30, height: 30),
        errorChild: const SizedBox(
            width: 30, height: 30, child: Icon(Icons.broken_image, size: 16)),
      ),
    );
  }

  /// The lazy slivers for one [section]: its title header + a virtualized
  /// [SliverGrid]. The grid only mounts the cells in (and just around) the
  /// viewport, so only VISIBLE custom-emoji images fetch + decode — keeping a
  /// big pack from loading hundreds of images at once. `addAutomaticKeepAlives`
  /// is off so scrolled-away cells (and their decoded images) are released.
  List<Widget> _sectionSlivers(NymColors c, _Section section, int columns) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          // `.emoji-default-cat-title` / `.emoji-pack-title`: flex space-between,
          // the star button trailing.
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.title.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  // `.emoji-picker-section-title`: 10px upper, ls1, dim.
                  style: TextStyle(
                      fontSize: 10, color: c.textDim, letterSpacing: 1),
                ),
              ),
              if (section.onToggleFavorite != null)
                _FavStar(
                  active: section.isFavorite,
                  onTap: section.onToggleFavorite!,
                ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.only(bottom: 10),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          delegate: SliverChildListDelegate(
            section.cells,
            addAutomaticKeepAlives: false,
          ),
        ),
      ),
    ];
  }
}

/// A single emoji section (title + flat list of cells); laid out into a lazy
/// grid by [_EmojiPickerState._sectionSlivers] which knows the column count.
class _Section {
  const _Section({
    required this.title,
    required this.cells,
    this.isFavorite = false,
    this.onToggleFavorite,
  });
  final String title;
  final List<Widget> cells;
  final bool isFavorite;

  /// When non-null, a favorite star is shown at the end of the title row.
  final VoidCallback? onToggleFavorite;
}

/// `.emoji-category-fav-btn` / `.emoji-pack-fav-btn`: a 14px star, dim by
/// default (hover → primary), filled `#F5C518` when active
/// (styles-components.css:1350-1380).
class _FavStar extends StatelessWidget {
  const _FavStar({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  static const Color _activeColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: active ? 'Unfavorite' : 'Favorite',
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          // `.emoji-category-fav-btn` / `.emoji-pack-fav-btn` (emoji.js:449/511):
          // the custom 5-point star — outline by default, filled gold `.active`.
          child: NymSvgIcon(
            active ? NymIcons.starFilled : NymIcons.starOutline,
            size: 14,
            color: active ? _activeColor : c.textDim,
          ),
        ),
      ),
    );
  }
}

/// `.emoji-btn` tap target: transparent, radius xs. On hover the cell fills
/// `rgba(255,255,255,0.08)` and the glyph scales to 1.15
/// (styles-components.css:2166-2171).
class _EmojiCell extends StatefulWidget {
  const _EmojiCell({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_EmojiCell> createState() => _EmojiCellState();
}

class _EmojiCellState extends State<_EmojiCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: Colors.transparent,
        borderRadius: NymRadius.rxs,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          hoverColor: Colors.white.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Center(
              child: AnimatedScale(
                scale: _hover ? 1.15 : 1.0,
                duration: const Duration(milliseconds: 120),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

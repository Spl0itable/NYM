// The enhanced reaction picker surface — a 1:1 port of the PWA's
// `.enhanced-emoji-modal` / `.reaction-picker` card (reactions.js
// `_ensureEnhancedEmojiModal`, lines 691-717; styles-components.css:1203-1341).
//
// Chrome (styles-components.css:1203-1219):
//   - card: `--bg-secondary`, 1px `--glass-border`, `--radius-md`, padding 12,
//     `--shadow-lg` (0 8px 32px black@0.5 dark; light-mode override
//     0 8px 32px black@0.12 + border rgba(0,0,0,0.08),
//     styles-themes-responsive.css:1161-1165), width 350, max-height 400,
//     overflow-y auto (the header scrolls WITH the content — it is not sticky).
//   - `.emoji-modal-header` (:1225-1232): flex row gap 10, padding-bottom 10,
//     1px glass bottom rule, margin-bottom 10. Contains the
//     `.emoji-search-input` (flex 1, :1245-1255) and the 28×28 `.modal-close
//     .emoji-modal-close` ✕ chip (:1234-1243).
//   - `.emoji-grid` (:1308-1312): 6 columns, gap 5 (5 columns ≤480px,
//     styles-themes-responsive.css:428-439).
//   - `.emoji-option` (:1325-1342): padding 8, 23px glyph, radius-xs,
//     transparent; hover white@0.08 + scale 1.15.
//
// Content: the same shared section markup as every picker surface
// (`_emojiSectionsHtml`, emoji.js:534-557) — Recently Used, custom NIP-30
// packs (fav → own → subscribed → rest, created_at desc, ≤50 packs of ≤120
// emojis), then default categories with favorite stars.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/nym_icons.dart';
import '../emoji/custom_emoji.dart';
import '../emoji/emoji_data.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';

/// Width breakpoint below which the `.emoji-grid` drops to 5 columns
/// (styles-themes-responsive.css:428 `max-width: 480px`).
const double _kFiveColMaxWidth = 480;

/// The `.enhanced-emoji-modal` card. [recents] is the current
/// most-recent-first list; selecting an emoji calls [onSelect] with the
/// literal char (unicode) or `:code:` (custom). [onClose] closes the modal
/// (the ✕ chip, `data-action="closeEnhancedEmojiModal"`).
class EnhancedEmojiModal extends ConsumerStatefulWidget {
  const EnhancedEmojiModal({
    super.key,
    required this.recents,
    required this.onSelect,
    required this.onClose,
    required this.width,
    required this.height,
  });

  /// Most-recent-first recents (unicode chars and/or `:code:` tokens).
  final List<String> recents;

  /// Called with the chosen emoji (unicode char or `:shortcode:`).
  final ValueChanged<String> onSelect;

  /// Closes the modal (the header ✕ chip).
  final VoidCallback onClose;

  /// Card width: 350, capped at 90% of the screen on mobile.
  final double width;

  /// Card height: 400 desktop / 80vh mobile (content always exceeds it).
  final double height;

  @override
  ConsumerState<EnhancedEmojiModal> createState() => _EnhancedEmojiModalState();
}

class _EnhancedEmojiModalState extends ConsumerState<EnhancedEmojiModal> {
  final _searchController = TextEditingController();
  String _query = '';

  late final Map<String, List<String>> _emojiToNames = buildEmojiToNames();

  // Favorite-star state (emoji.js `nym_emoji_category_favorites` /
  // `nym_emoji_pack_favorites`). Loaded lazily once prefs resolve; toggling a
  // star reorders that block to the top live and persists (the PWA marks the
  // cached modal dirty and rebuilds — setState is our equivalent).
  EmojiFavoritesStore? _catFavStore;
  EmojiFavoritesStore? _packFavStore;
  List<String> _categoryFavorites = const [];
  List<String> _packFavorites = const [];

  @override
  void initState() {
    super.initState();
    _loadFavorites();
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
    _searchController.dispose();
    super.dispose();
  }

  /// Recents filtered to drop custom `:code:` tokens whose pack is no longer
  /// known (emoji.js `_recentEmojisForPicker`, lines 150-159). The PWA caps the
  /// picker recents at 20 on mobile (`innerWidth<=768`) / 24 on desktop.
  List<String> _visibleRecents(CustomEmojiState custom, double width) {
    final cap = width <= 768 ? 20 : kRecentEmojisCap;
    return widget.recents.where((e) {
      final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
      if (m == null) return true;
      return custom.codeToUrl.containsKey(m.group(1));
    }).take(cap).toList();
  }

  /// True when an emoji passes the current search (reactions.js
  /// `_applyEmojiSearch`: matches the char itself or any of its names).
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
    final custom = ref.watch(liveCustomEmojiProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final columns = screenWidth <= _kFiveColMaxWidth ? 5 : 6;

    final sections = <_Section>[];

    // Recently Used.
    final recents = _visibleRecents(custom, screenWidth)
        .where((e) {
          final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
          return m == null ? _matches(e) : _matchesCustom(m.group(1)!);
        })
        .toList();
    if (recents.isNotEmpty) {
      sections.add(_Section(
        title: tr('Recently Used'),
        cells: recents.map((e) {
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
    // created_at desc (emoji.js `buildCustomEmojiSectionsHtml`:487-495).
    // Own/subscribed packs get a ` ★` title suffix.
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
    // At most 50 pack sections, each sliced to its first 120 known emojis
    // (`buildCustomEmojiSectionsHtml`, emoji.js:499-504). The 50-pack budget
    // counts packs with ≥1 KNOWN emoji; the search filter only hides buttons
    // afterwards, so it doesn't free slots.
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
      final packTitle = pack.title.isEmpty ? tr('Emoji pack') : pack.title;
      sections.add(_Section(
        title: '$packTitle$star',
        cells: cells,
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
      sections.add(_Section(
        title: '${category[0].toUpperCase()}${category.substring(1)}',
        cells: cells,
        isFavorite: _categoryFavorites.contains(category),
        onToggleFavorite: _catFavStore == null
            ? null
            : () => _toggleCategoryFavorite(category),
      ));
    }

    // `.enhanced-emoji-modal`: bg-secondary card, 1px glass border, radius-md,
    // padding 12, shadow-lg, overflow-y auto. Light mode overrides the shadow
    // to 0 8px 32px rgba(0,0,0,0.12) and the border to rgba(0,0,0,0.08) — the
    // light `glassBorder` token IS rgba(0,0,0,0.08), so only the shadow needs
    // an explicit swap (styles-themes-responsive.css:1161-1165).
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
          boxShadow: [
            BoxShadow(
              color: c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(12),
        child: CustomScrollView(
          // The whole modal scrolls (`overflow-y: auto`) — the header is part
          // of the content, NOT sticky. Lazy slivers keep only visible
          // custom-emoji images decoded (the PWA's `loading="lazy"`).
          slivers: [
            SliverToBoxAdapter(child: _header(c)),
            for (final s in sections) ..._sectionSlivers(c, s, columns),
          ],
        ),
      ),
    );
  }

  /// `.emoji-modal-header`: search + 28×28 ✕ chip in a row (gap 10), 1px glass
  /// bottom rule (padding-bottom 10, margin-bottom 10).
  Widget _header(NymColors c) {
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: _search(c)),
          const SizedBox(width: 10),
          _ModalCloseChip(onTap: widget.onClose),
        ],
      ),
    );
  }

  /// `.emoji-search-input` (styles-components.css:1245-1255): white@0.05 fill,
  /// 1px glass border, radius-xs, 12px `--text-bright` (light mode overrides
  /// the color to `--text`, styles-themes-responsive.css:1063-1068), padding
  /// 7px 10px, placeholder "Search emoji by name...". The global
  /// `body.light-mode input` rule forces a black@0.04 fill and black@0.1
  /// border (styles-themes-responsive.css:561-568).
  Widget _search(NymColors c) {
    final Color fill = c.isLight
        ? Colors.black.withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: 0.05);
    final Color borderColor =
        c.isLight ? Colors.black.withValues(alpha: 0.1) : c.glassBorder;
    return TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _query = _sanitizeUserText(v).trim()),
      style: TextStyle(color: c.isLight ? c.text : c.textBright, fontSize: 12),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        hintText: tr('Search emoji by name...'),
        hintStyle: TextStyle(color: c.textDim, fontSize: 12),
        filled: true,
        fillColor: fill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: borderColor),
        ),
        // `.emoji-search-input` has no :focus override (unlike the composer's
        // `.emoji-picker-search-input:focus`), so the border stays glass.
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: borderColor),
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
        out.write('�');
        continue;
      }
      // Unpaired low surrogate -> replacement.
      if (u >= 0xDC00 && u <= 0xDFFF) {
        out.write('�');
        continue;
      }
      out.writeCharCode(u);
    }
    return out.toString();
  }

  /// `.emoji-option` with a unicode glyph: 23px text.
  Widget _unicodeCell(String emoji) {
    return _EmojiOptionCell(
      onTap: () => widget.onSelect(emoji),
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 23, height: 1.1),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// `.emoji-option.custom-emoji-option`: a 30×30 image
  /// (emoji.js `renderCustomEmojiImg`). Selecting inserts `:shortcode:`.
  Widget _customCell(String shortcode, String url) {
    return _EmojiOptionCell(
      onTap: () => widget.onSelect(':$shortcode:'),
      child: InlineNetworkImage(
        // Route through the media proxy (PWA getProxiedEmojiUrl).
        url: proxiedMedia(url, emoji: true),
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        memoryOnly: true,
        retryOnError: true,
        placeholder: const SizedBox(width: 30, height: 30),
        errorChild: const SizedBox(
            width: 30, height: 30, child: Icon(Icons.broken_image, size: 16)),
      ),
    );
  }

  /// The lazy slivers for one [section]: `.emoji-section-title` (10px dim
  /// UPPERCASE ls1, margin-bottom 5) + the `.emoji-grid` (gap 5), the section
  /// closing with `.emoji-section`'s 15px bottom margin.
  List<Widget> _sectionSlivers(NymColors c, _Section section, int columns) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 5),
          // `.emoji-default-cat-title` / `.emoji-pack-title`: flex
          // space-between, the star button trailing.
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.title.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
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
        padding: const EdgeInsets.only(bottom: 15),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
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

/// A single emoji section (title + flat list of cells).
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

/// The header's `.modal-close.emoji-modal-close` chip: 28×28 (the `.modal-close`
/// base 32×32 is overridden, styles-components.css:1234-1243), circular,
/// white@0.05 fill, 1px glass border, 14px ✕ in `--text-dim`; hover swaps to
/// the danger palette (`.modal-close:hover`, styles-components.css:111-115).
class _ModalCloseChip extends StatefulWidget {
  const _ModalCloseChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ModalCloseChip> createState() => _ModalCloseChipState();
}

class _ModalCloseChipState extends State<_ModalCloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? const Color(0x1FFF4444) // rgba(255,68,68,0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover
                  ? const Color(0x4DFF4444) // rgba(255,68,68,0.3)
                  : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 14,
              height: 1,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.emoji-category-fav-btn` / `.emoji-pack-fav-btn`: a 14px star, dim by
/// default (hover → primary), filled `#F5C518` when active
/// (styles-components.css:1276-1306, 1350-1380).
class _FavStar extends StatelessWidget {
  const _FavStar({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  static const Color _activeColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: active ? tr('Unfavorite') : tr('Favorite'),
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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

/// `.emoji-option` tap target: transparent, radius-xs, padding 8. On hover the
/// cell fills `rgba(255,255,255,0.08)` and the glyph scales to 1.15
/// (styles-components.css:1325-1342).
class _EmojiOptionCell extends StatefulWidget {
  const _EmojiOptionCell({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_EmojiOptionCell> createState() => _EmojiOptionCellState();
}

class _EmojiOptionCellState extends State<_EmojiOptionCell> {
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
            padding: const EdgeInsets.all(8),
            child: Center(
              // `transition: all var(--transition)` = 0.25s
              // cubic-bezier(0.4,0,0.2,1) (styles-components.css:1333).
              child: AnimatedScale(
                scale: _hover ? 1.15 : 1.0,
                duration: NymMotion.transition,
                curve: NymMotion.curve,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

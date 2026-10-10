// Composer emoji picker: search header, recents, custom NIP-30 packs, then default categories; 6 columns, 5 at ≤480px.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart' show proxiedMedia;
import '../messages/inline_network_image.dart';
import 'custom_emoji.dart';
import 'emoji_data.dart';
import 'modal_close_chip.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_tooltip.dart';
import '../../widgets/common/hit_slop.dart';
import '../../core/theme/nym_a11y.dart';

/// Below this width the grid drops to 5 columns.
const double _kFiveColMaxWidth = 480;

/// [onSelect] gets the unicode char or `:code:`; the host updates recents and inserts.
class EmojiPicker extends ConsumerStatefulWidget {
  const EmojiPicker({
    super.key,
    required this.recents,
    required this.onSelect,
    this.onClose,
    this.proxyBase,
    this.tabs,
  });

  final Widget? tabs;

  /// Most-recent-first unicode chars and/or `:code:` tokens.
  final List<String> recents;

  final ValueChanged<String> onSelect;

  /// When null, close pops an enclosing modal route; overlay-portal hosts should pass their `hide`.
  final VoidCallback? onClose;

  /// Optional media proxy base for custom emoji images.
  final String? proxyBase;

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  String _query = '';

  late final Map<String, List<String>> _emojiToNames = buildEmojiToNames();

  // Favorite stars load lazily; toggling reorders the block live and persists.
  EmojiFavoritesStore? _catFavStore;
  EmojiFavoritesStore? _packFavStore;
  List<String> _categoryFavorites = const [];
  List<String> _packFavorites = const [];

  @override
  void initState() {
    super.initState();
    // `View.viewInsets` sets up no rebuild dependency, so observe metrics to follow the keyboard.
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

  /// Drops custom tokens whose pack is unknown; capped at 20 on mobile, 24 on desktop.
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

  /// Matches the char itself or any of its names.
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

  /// Custom emoji match on the shortcode.
  bool _matchesCustom(String shortcode) {
    if (_query.isEmpty) return true;
    return shortcode.toLowerCase().contains(_query.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // The live NIP-30 store, hydrated from cache and updated as packs arrive.
    final custom = ref.watch(liveCustomEmojiProvider);
    final transparency =
        ref.watch(settingsProvider.select((s) => s.transparencyEnabled));
    final width = MediaQuery.sizeOf(context).width;
    final columns = width <= _kFiveColMaxWidth ? 5 : 6;

    final sections = <_Section>[];

    final recents = _visibleRecents(custom, width).where((e) {
      final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
      return m == null ? _matches(e) : _matchesCustom(m.group(1)!);
    }).toList();
    if (recents.isNotEmpty) {
      sections.add(_section(
        c,
        title: tr('Recently Used'),
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

    // Packs ranked fav, own, subscribed, rest, then newest; own/subscribed get a ` ★` suffix.
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
    // At most 50 packs with a known emoji, 120 emojis each; search only hides cells, freeing no slots.
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
      final owned = isOwn(pack) || isSubscribed(pack);
      // An empty cached title still gets a section header.
      final packTitle = pack.title.isEmpty ? tr('Emoji pack') : pack.title;
      sections.add(_section(
        c,
        title: packTitle,
        owned: owned,
        children: cells,
        isFavorite: packFavSet.contains(pack.key),
        onToggleFavorite:
            _packFavStore == null ? null : () => _togglePackFavorite(pack.key),
      ));
    }

    // Favorited categories hoisted to the top of the block.
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

    // Pad up by the keyboard via raw `View.viewInsets`; MediaQuery's insets are already consumed under a resizing Scaffold.
    final view = View.of(context);
    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    final maxPanelHeight = keyboardInset > 0
        // Screen minus keyboard, status bar and the 60px bottom-bar anchor (+8).
        ? (MediaQuery.sizeOf(context).height -
                keyboardInset -
                MediaQuery.paddingOf(context).top -
                68)
            .clamp(160.0, 400.0)
            .toDouble()
        : 400.0;

    // Supplies a Material and bounded constraints so the picker mounts safely in overlays.
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: ConstrainedBox(
          // Width 350, max height 400; phones cap at 90% width.
          constraints: BoxConstraints(
              maxWidth: width <= 768 ? (width * 0.9).clamp(0.0, 350.0) : 350.0,
              maxHeight: maxPanelHeight),
          child: LayoutBuilder(builder: (context, constraints) {
            final height = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : maxPanelHeight;
            return Container(
              height: height,
              decoration: BoxDecoration(
                // Transparency uses the themed secondary background; solid-ui uses the opaque glass background.
                color: transparency ? c.bgSecondary : c.glassBg,
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rmd,
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
                  ?widget.tabs,
                  _header(c),
                  const SizedBox(height: 10),
                  Expanded(
                    child: CustomScrollView(
                      // Lazy slivers mount only visible cells; eager grids loaded every pack image at once and ran out of memory.
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
          ModalCloseChip(onTap: _handleClose),
        ],
      ),
    );
  }

  /// Prefer the host's [EmojiPicker.onClose], else pop a modal route, else do nothing.
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

  Widget _search(NymColors c) {
    // TextField needs a Material within the closest LookupBoundary, so wrap the input itself.
    return Material(
      type: MaterialType.transparency,
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = _sanitizeUserText(v).trim()),
        // Light mode uses `--text` for this input.
        style:
            TextStyle(color: c.isLight ? c.text : c.textBright, fontSize: 12),
        cursorColor: c.isLight ? c.text : c.textBright,
        decoration: NymField.decoration(c,
            hint: tr('Search emoji...'),
          minHeight: largeFieldMin(context),
            fontSize: 12,
            radius: NymRadius.rxs,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7)),
      ),
    );
  }

  /// Replaces unpaired surrogates the Android IME can send, avoiding crashes.
  static String _sanitizeUserText(String input) {
    final units = input.codeUnits;
    final out = StringBuffer();
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
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
        out.write('\uFFFD');
        continue;
      }
      if (u >= 0xDC00 && u <= 0xDFFF) {
        out.write('\uFFFD');
        continue;
      }
      out.writeCharCode(u);
    }
    return out.toString();
  }

  /// Section title plus grid; [onToggleFavorite] adds a trailing favorite star.
  _Section _section(NymColors c,
      {required String title,
      required List<Widget> children,
      bool isFavorite = false,
      bool owned = false,
      VoidCallback? onToggleFavorite}) {
    return _Section(
      title: title,
      cells: children,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      owned: owned,
    );
  }

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

  /// 30x30 custom emoji image; selecting inserts `:shortcode:`.
  Widget _customCell(String shortcode, String url) {
    return _EmojiCell(
      onTap: () => widget.onSelect(':$shortcode:'),
      // SVG-aware and decode-safe; an undecodable image shows a broken-image glyph instead of throwing.
      child: InlineNetworkImage(
        // Always proxied so the user's IP is hidden from the host; an explicit [proxyBase] wins (tests).
        url: (widget.proxyBase != null && widget.proxyBase!.isNotEmpty)
            ? proxiedEmojiUrl(url, widget.proxyBase)
            : proxiedMedia(url, emoji: true),
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        // Memory-only so a gridful of cells doesn't lock the cache manager's sqflite DB.
        memoryOnly: true,
        // Two cache-busting retries at 800ms·n.
        retryOnError: true,
        placeholder: const SizedBox(width: 30, height: 30),
        errorChild: const SizedBox(
            width: 30, height: 30, child: Icon(Icons.broken_image, size: 16)),
      ),
    );
  }

  /// Title plus a virtualized grid; keep-alives are off so scrolled-away images are released.
  List<Widget> _sectionSlivers(NymColors c, _Section section, int columns) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        section.title.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10, color: c.textDim, letterSpacing: 1),
                      ),
                    ),
                    if (section.owned) ...[
                      const SizedBox(width: 4),
                      NymSvgIcon(
                        NymIcons.starFilled,
                        key: const ValueKey('emoji-pack-owned-star'),
                        size: 9,
                        color: c.textDim,
                      ),
                    ],
                  ],
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

/// Title plus flat cells, laid out lazily by [_EmojiPickerState._sectionSlivers].
class _Section {
  const _Section({
    required this.title,
    required this.cells,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.owned = false,
  });
  final String title;
  final List<Widget> cells;
  final bool isFavorite;
  final bool owned;

  /// When non-null, a favorite star ends the title row.
  final VoidCallback? onToggleFavorite;
}

/// 14px favorite star, dim by default and filled `#F5C518` when active.
class _FavStar extends StatelessWidget {
  const _FavStar({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  static const Color _activeColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return HitSlop(child: NymTooltip(
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
    ));
  }
}

/// Emoji cell that fills and scales to 1.15 on hover.
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

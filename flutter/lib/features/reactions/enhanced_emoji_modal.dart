// Enhanced reaction picker card: search header, recents, custom packs, then default categories with favorite stars.

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
import '../../widgets/common/nym_focusable.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_tooltip.dart';

/// Below this width the grid drops to 5 columns.
const double _kFiveColMaxWidth = 480;

/// [onSelect] gets the unicode char or `:code:` for custom emoji.
class EnhancedEmojiModal extends ConsumerStatefulWidget {
  const EnhancedEmojiModal({
    super.key,
    required this.recents,
    required this.onSelect,
    required this.onClose,
    required this.width,
    required this.height,
  });

  /// Most-recent-first unicode chars and/or `:code:` tokens.
  final List<String> recents;

  final ValueChanged<String> onSelect;

  final VoidCallback onClose;

  /// 350, capped at 90% of the screen on mobile.
  final double width;

  /// 400 on desktop, 80% of the screen on mobile.
  final double height;

  @override
  ConsumerState<EnhancedEmojiModal> createState() => _EnhancedEmojiModalState();
}

class _EnhancedEmojiModalState extends ConsumerState<EnhancedEmojiModal> {
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
    final custom = ref.watch(liveCustomEmojiProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final columns = screenWidth <= _kFiveColMaxWidth ? 5 : 6;

    final sections = <_Section>[];

    final recents = _visibleRecents(custom, screenWidth).where((e) {
      final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
      return m == null ? _matches(e) : _matchesCustom(m.group(1)!);
    }).toList();
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
      sections.add(_Section(
        title: packTitle,
        owned: owned,
        cells: cells,
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
      sections.add(_Section(
        title: '${category[0].toUpperCase()}${category.substring(1)}',
        cells: cells,
        isFavorite: _categoryFavorites.contains(category),
        onToggleFavorite: _catFavStore == null
            ? null
            : () => _toggleCategoryFavorite(category),
      ));
    }

    // Light mode swaps only the shadow; the light glass border token already matches.
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
              color:
                  c.isLight ? const Color(0x1F000000) : const Color(0x80000000),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(12),
        child: CustomScrollView(
          // The header scrolls with the content; lazy slivers keep only visible images decoded.
          slivers: [
            SliverToBoxAdapter(child: _header(c)),
            for (final s in sections) ..._sectionSlivers(c, s, columns),
          ],
        ),
      ),
    );
  }

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

  /// Search input; light mode forces the global input fill and border.
  Widget _search(NymColors c) {
    return TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _query = _sanitizeUserText(v).trim()),
      style: TextStyle(color: c.inputText, fontSize: 12),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: NymField.decoration(c,
          hint: tr('Search emoji...'),
          fontSize: 12,
          radius: NymRadius.rxs,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 7)),
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
        out.write('�');
        continue;
      }
      if (u >= 0xDC00 && u <= 0xDFFF) {
        out.write('�');
        continue;
      }
      out.writeCharCode(u);
    }
    return out.toString();
  }

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

  /// 30x30 custom emoji image; selecting inserts `:shortcode:`.
  Widget _customCell(String shortcode, String url) {
    return _EmojiOptionCell(
      onTap: () => widget.onSelect(':$shortcode:'),
      child: InlineNetworkImage(
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

  /// Lazy slivers for one section: title, grid, then a 15px bottom margin.
  List<Widget> _sectionSlivers(NymColors c, _Section section, int columns) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 5),
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

/// 28x28 circular close chip that turns danger-red on hover.
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
    return NymFocusable(
      onActivate: widget.onTap,
      tooltip: tr('Close'),
      excludeChildSemantics: true,
      radius: const BorderRadius.all(Radius.circular(16)),
      child: MouseRegion(
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
                  ? const Color(0x1FFF4444)
                  : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: _hover
                    ? const Color(0x4DFF4444)
                    : c.glassBorder,
              ),
            ),
            child: Icon(
              Icons.close,
              size: 14,
              color: _hover ? c.danger : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
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
    return NymTooltip(
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

/// Emoji cell that fills and scales to 1.15 on hover.
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
              // 0.25s cubic-bezier(0.4, 0, 0.2, 1).
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

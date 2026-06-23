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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'custom_emoji.dart';
import 'emoji_data.dart';

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
    this.proxyBase,
  });

  /// Most-recent-first recents (unicode chars and/or `:code:` tokens).
  final List<String> recents;

  /// Called with the chosen emoji (unicode char or `:shortcode:`).
  final ValueChanged<String> onSelect;

  /// Optional media/emoji proxy base for custom emoji images.
  final String? proxyBase;

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  late final Map<String, List<String>> _emojiToNames = buildEmojiToNames();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Recents filtered to drop custom `:code:` tokens whose pack is no longer
  /// known (emoji.js `_recentEmojisForPicker`, lines 150-159). The PWA caps at
  /// 20 on mobile / 24 desktop; we use the full cap of 24 (composer is the same
  /// surface regardless of platform here).
  List<String> _visibleRecents(CustomEmojiState custom) {
    return widget.recents.where((e) {
      final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
      if (m == null) return true;
      return custom.codeToUrl.containsKey(m.group(1));
    }).take(kRecentEmojisCap).toList();
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
    final custom = ref.watch(customEmojiStateProvider);
    final width = MediaQuery.sizeOf(context).width;
    final columns = width <= _kFiveColMaxWidth ? 5 : 6;

    final sections = <_Section>[];

    // Recently Used.
    final recents = _visibleRecents(custom)
        .where((e) {
          final m = RegExp(r'^:([a-zA-Z0-9_]+):$').firstMatch(e);
          return m == null ? _matches(e) : _matchesCustom(m.group(1)!);
        })
        .toList();
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

    // Custom NIP-30 packs.
    for (final pack in custom.packs) {
      final cells = <Widget>[];
      for (final e in pack.emojis) {
        if (!custom.codeToUrl.containsKey(e.shortcode)) continue;
        if (!_matchesCustom(e.shortcode)) continue;
        cells.add(_customCell(e.shortcode, custom.codeToUrl[e.shortcode]!));
      }
      if (cells.isEmpty) continue;
      sections.add(_section(c, title: pack.title, children: cells));
    }

    // Default categories.
    for (final category in kEmojiCategoryOrder) {
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
      ));
    }

    return Container(
      // .emoji-picker: glass bg, glass border, radius md, padding 12,
      // max 360×400, scroll-y (styles-components.css:2090-2106).
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 400),
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
          _search(c),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: LayoutBuilder(builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: sections.isEmpty
                      ? [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'No emoji found',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: c.textDim, fontSize: 12),
                            ),
                          ),
                        ]
                      : [
                          for (final s in sections)
                            _GridSection(columns: columns, section: s),
                        ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// `.emoji-picker-search-input` (styles-components.css:2121-2135).
  Widget _search(NymColors c) {
    return TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _query = v.trim()),
      style: TextStyle(color: c.textBright, fontSize: 12),
      cursorColor: c.primary,
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
    );
  }

  /// `.emoji-picker-section` + `.emoji-picker-section-title` (10px uppercase
  /// dim, letter-spacing 1) wrapping a grid (styles-components.css:2137-2154).
  _Section _section(NymColors c,
      {required String title, required List<Widget> children}) {
    return _Section(title: title, cells: children);
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
      child: CachedNetworkImage(
        imageUrl: proxiedEmojiUrl(url, widget.proxyBase),
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox(width: 30, height: 30),
        errorWidget: (_, __, ___) =>
            const SizedBox(width: 30, height: 30, child: Icon(Icons.broken_image, size: 16)),
      ),
    );
  }
}

/// A single emoji section (title + flat list of cells); laid out into a grid by
/// [_GridSection] which knows the column count.
class _Section {
  const _Section({required this.title, required this.cells});
  final String title;
  final List<Widget> cells;
}

/// Renders one [_Section] as a titled responsive grid.
class _GridSection extends StatelessWidget {
  const _GridSection({required this.columns, required this.section});
  final int columns;
  final _Section section;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              section.title.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                color: c.textDim,
                letterSpacing: 1,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: columns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            children: section.cells,
          ),
        ],
      ),
    );
  }
}

/// `.emoji-btn` tap target: transparent, radius xs, hover highlight.
class _EmojiCell extends StatelessWidget {
  const _EmojiCell({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: NymRadius.rxs,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Center(child: child),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/common/nym_field.dart';
import '../i18n/i18n.dart';
import 'geo_explore.dart';

class GeoSearchField extends StatefulWidget {
  const GeoSearchField({
    super.key,
    required this.loadPlaces,
    required this.onPick,
  });

  final Future<List<GeoPlace>> Function() loadPlaces;
  final void Function(String geohash) onPick;

  @override
  State<GeoSearchField> createState() => _GeoSearchFieldState();
}

class _GeoSearchFieldState extends State<GeoSearchField> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  Future<List<GeoPlace>>? _placesFuture;
  List<GeoPlace> _places = const [];
  List<GeoSearchResult> _results = const [];
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _ensurePlaces() {
    if (_placesFuture != null) return;
    final f = widget.loadPlaces();
    _placesFuture = f;
    f.then((p) {
      if (!mounted) return;
      _places = p;
      _recompute();
    }, onError: (_) {
      _placesFuture = null;
    });
  }

  void _onChanged(String _) {
    if (_text.text.trim().isNotEmpty) _ensurePlaces();
    _recompute();
  }

  void _recompute() {
    setState(() {
      _results = buildGeoSearchResults(_places, _text.text);
      final first = _results.indexWhere((r) => r.type != 'invalid');
      _highlight = first < 0 ? 0 : first;
    });
  }

  void _clear() {
    _text.clear();
    setState(() {
      _results = const [];
      _highlight = 0;
    });
  }

  void _pick(GeoSearchResult r) {
    final gh = r.geohash;
    if (gh == null) return;
    _clear();
    _focus.unfocus();
    widget.onPick(gh);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final selectable = [
      for (var i = 0; i < _results.length; i++)
        if (_results[i].type != 'invalid') i,
    ];
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (selectable.isEmpty) return KeyEventResult.handled;
      final at = selectable.indexOf(_highlight);
      final next = k == LogicalKeyboardKey.arrowDown
          ? (at + 1) % selectable.length
          : (at <= 0 ? selectable.length - 1 : at - 1);
      setState(() => _highlight = selectable[next]);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (selectable.contains(_highlight)) _pick(_results[_highlight]);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _text.text.isNotEmpty) {
      _clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _invalidText(String? reason) => reason == 'length'
      ? tr('A geohash has at most 12 characters.')
      : tr('Geohashes use 0–9 and the letters b–z except i, l and o.');

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final field = NymFieldBox(
      overlay: true,
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search, size: 18, color: NymField.icon(nym)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('geo-search-input'),
              controller: _text,
              focusNode: _focus,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                if (_highlight < _results.length &&
                    _results[_highlight].type != 'invalid') {
                  _pick(_results[_highlight]);
                }
              },
              style: TextStyle(fontSize: 14, color: nym.text),
              cursorColor: nym.primary,
              decoration: NymField.bare(nym,
                  hint: tr('Search a place or geohash'), fontSize: 14),
            ),
          ),
          if (_text.text.isNotEmpty)
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                tooltip: tr('Clear search'),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close, size: 18, color: NymField.icon(nym)),
                onPressed: _clear,
              ),
            ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        if (_results.isNotEmpty) const SizedBox(height: 6),
        if (_results.isNotEmpty)
          Container(
          constraints: const BoxConstraints(maxHeight: 300),
          decoration: BoxDecoration(
            color: nym.isLight ? const Color(0xF7FFFFFF) : const Color(0xF2000000),
            border: Border.all(color: nym.glassBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              for (var i = 0; i < _results.length; i++)
                _row(_results[i], i == _highlight, nym),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(GeoSearchResult r, bool highlighted, NymColors nym) {
    if (r.type == 'invalid') {
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text(
            _invalidText(r.reason),
            style: TextStyle(fontSize: 12, color: nym.warning),
          ),
        ),
      );
    }
    final String title;
    final String subtitle;
    if (r.type == 'geohash') {
      title = tr('Go to #{geohash}', {'geohash': r.geohash});
      subtitle = tr('Geohash');
    } else {
      final p = r.match!.place;
      title = p.name;
      final where = [
        if (p.region.isNotEmpty && p.region != p.name) p.region,
        if (p.country.isNotEmpty) p.country,
      ].join(', ');
      subtitle = where.isEmpty ? '#${r.geohash}' : '$where · #${r.geohash}';
    }
    return Semantics(
      button: true,
      selected: highlighted,
      label: '$title, $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _pick(r),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          color: highlighted ? nym.primaryA(0.14) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: highlighted ? nym.primary : nym.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: nym.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

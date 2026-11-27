import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_context_menu.dart';
import '../../features/channels/geohash_place_cache.dart';
import '../../features/settings/settings_helpers.dart';
import '../../models/channel.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../nym_icons.dart';
import 'row_preview.dart';
import 'sidebar_chrome.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_row_menu_button.dart';
import 'unread_pill.dart';
import '../common/nym_tooltip.dart';

/// Gray tint for a favorited channel row that is not active.
const Color _pinnedGrey = Color(0xFF9696A0);

/// A sidebar channel row; a 500ms hold opens the quick menu (see [SidebarRowGestures]).
class ChannelListItem extends ConsumerWidget {
  const ChannelListItem({
    super.key,
    required this.entry,
    required this.active,
    required this.pinned,
    required this.unread,
    required this.textSize,
    required this.onTap,
    this.mesh = false,
    this.reorder = true,
  });

  final ChannelEntry entry;
  final bool active;
  final bool pinned;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  final bool mesh;

  final bool reorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final name = '#${entry.isGeohash ? entry.geohashKey : entry.channel}';
    final showPinned = pinned && !active;
    final location = entry.isGeohash ? geohashLocationLabel(entry.geohashKey) : '';

    final Color activeFill =
        c.isLight ? Colors.black.withValues(alpha: 0.06) : c.primaryA(0.10);
    // Hover loses to active but beats pinned, following the CSS cascade order.
    final Color hoverFill = sidebarRowHoverFill(c);
    final Color borderColor = active
        ? c.primaryA(0.20)
        : (showPinned
            ? _pinnedGrey.withValues(alpha: 0.20)
            : Colors.transparent);
    final List<BoxShadow>? glow = active
        ? (c.isLight
            ? null
            : [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)])
        : (showPinned
            ? [
                BoxShadow(
                    color: _pinnedGrey.withValues(alpha: 0.05), blurRadius: 12)
              ]
            : null);

    final nameText = Text(
      name,
      key: const ValueKey('sidebarName'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: c.text,
        fontSize: textSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );

    final preview = sidebarRowPreview(ref, entry.storageKey, 'channel');
    final hasMenu = buildChannelMenuActions(context, ref, entry).isNotEmpty;
    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameText,
        if (preview.text.isNotEmpty)
          rowPreviewLine(context, preview.text, 'channel', preview.dim,
              preview.sender, preview.bodyAt)
        else
          _ChannelLocationLine(
            geohash: entry.geohashKey,
            textSize: textSize,
          ),
      ],
    );

    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SidebarRowGestures(
        onTap: onTap,
        onShowMenu: (pos) =>
            maybeShowChannelContextMenu(context, ref, entry, pos),
        builder: (context, hovered) {
          final Color fill = active
              ? activeFill
              : hovered
                  ? hoverFill
                  : (showPinned
                      ? _pinnedGrey.withValues(alpha: 0.10)
                      : Colors.transparent);
          return Stack(
            children: [
              Container(
                key: const ValueKey('sidebarRowBox'),
                constraints: BoxConstraints(minHeight: sidebarRowMinH()),
                padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 6, 12, 6),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: borderColor, width: 1),
                  boxShadow: glow,
                ),
                child: Row(
                  children: [
                    SidebarChannelTile(geohash: entry.isGeohash),
                    const SizedBox(width: kSidebarGap),
                    Expanded(
                      child: location.isEmpty
                          ? nameBlock
                          : NymTooltip(message: location, child: nameBlock),
                    ),
                    if (mesh) ...[
                      const SizedBox(width: 5),
                      NymSvgIcon(NymIcons.bluetooth,
                          size: 12, color: c.primary),
                    ],
                    rowTimeLabel(context, preview.time),
                    ChatNavRowBadges(storageKey: entry.storageKey),
                    if (unread > 0) ...[
                      const SizedBox(width: 5),
                      SidebarUnreadPill(count: unread),
                    ],
                    if (hasMenu) const SizedBox(width: kSidebarMenuReserve),
                  ],
                ),
              ),
              if (hasMenu)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: SidebarRowMenuButton(
                    semanticLabel: 'Channel menu',
                    onShowMenu: (pos) =>
                        maybeShowChannelContextMenu(context, ref, entry, pos),
                  ),
                ),
              if (active || showPinned)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: active ? c.primary : c.textDim,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: active
                                  ? c.primaryA(0.4)
                                  : _pinnedGrey.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (!reorder) return row;
    return PinnedReorder(
      storageKey: entry.storageKey,
      onHoldMenu: (pos) =>
          maybeShowChannelContextMenu(context, ref, entry, pos),
      child: row,
    );
  }
}

class SidebarChannelTile extends StatelessWidget {
  const SidebarChannelTile({super.key, required this.geohash, this.svg});

  final bool geohash;
  final String? svg;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('sidebarLead'),
        width: kSidebarIcon,
        height: kSidebarIcon,
        alignment: Alignment.center,
        child: Container(
          key: const ValueKey('channelTile'),
          width: kSidebarIcon,
          height: kSidebarIcon,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.primaryA(0.14),
            borderRadius:
                const BorderRadius.all(Radius.circular(kSidebarIcon * 10 / 36)),
          ),
          child: NymSvgIcon(svg ?? channelGlyphSvg(geohash: geohash),
              size: kSidebarIcon / 2, color: c.primary),
        ),
      ),
    );
  }
}

/// Location line under a channel name: decoded coordinates at once, upgraded in place when the lookup lands.
class _ChannelLocationLine extends ConsumerStatefulWidget {
  const _ChannelLocationLine({required this.geohash, required this.textSize});

  /// Empty for a named (non-geohash) channel.
  final String geohash;
  final double textSize;

  @override
  ConsumerState<_ChannelLocationLine> createState() =>
      _ChannelLocationLineState();
}

class _ChannelLocationLineState extends ConsumerState<_ChannelLocationLine>
    with WidgetsBindingObserver {
  String? _place;

  /// Local fallback description for a cell the geocoder cannot name; a real name still wins.
  String? _region;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prime(initial: true);
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resuming the app is the natural moment to retry a name that failed earlier.
    if (state == AppLifecycleState.resumed && _place == null) {
      _prime(force: true);
    }
  }

  @override
  void didUpdateWidget(covariant _ChannelLocationLine old) {
    super.didUpdateWidget(old);
    if (old.geohash != widget.geohash) {
      _place = null;
      _region = null;
      _retry?.cancel();
      _prime();
    }
  }

  void _prime({bool force = false, bool initial = false}) {
    final gh = widget.geohash;
    if (gh.isEmpty) return;
    final cache = ref.read(geohashPlaceCacheProvider);
    final hit = cache.cached(gh);
    if (hit != null) {
      // Must setState outside initState, or the row keeps showing coordinates until an unrelated rebuild.
      if (initial) {
        _place = hit;
      } else {
        setState(() => _place = hit);
      }
      return;
    }
    final stored = cache.missLabel(gh);
    if (stored != null && stored.isNotEmpty && _region != stored) {
      if (initial) {
        _region = stored;
      } else {
        setState(() => _region = stored);
      }
    }
    cache.resolve(gh, force: force).then((place) {
      if (!mounted || widget.geohash != gh) return;
      if (place.isNotEmpty) {
        setState(() => _place = place);
        return;
      }
      // Some cells have no address (open ocean), so describe the region from bundled map data.
      cache.describeRegionFor(gh).then((desc) {
        if (!mounted || widget.geohash != gh || desc.isEmpty) return;
        if (_place != null) return;
        setState(() => _region = desc);
      });
      // Nothing else re-triggers a lookup, so the row schedules its own retry.
      _scheduleRetry(cache, gh);
    });
  }

  void _scheduleRetry(GeohashPlaceCache cache, String gh) {
    _retry?.cancel();
    final at = cache.retryAt(gh);
    if (at == null) return; // Accepted as having no name.
    final wait = at.difference(DateTime.now());
    _retry = Timer(wait.isNegative ? const Duration(seconds: 1) : wait, () {
      if (mounted && widget.geohash == gh && _place == null) _prime();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final gh = widget.geohash;
    final text = gh.isEmpty
        ? 'Not a geohash'
        : (_place ?? _region ?? geohashLocationLabel(gh));
    if (text.isEmpty) return const SizedBox.shrink();
    final size = widget.textSize - 3;
    final style = TextStyle(
      color: c.textDim,
      fontSize: size,
      height: math.max(kSidebarSubLine, size * 1.3) / size,
    );
    final splitIdx = _place != null ? text.lastIndexOf(', ') : -1;
    final Widget line;
    if (splitIdx > 0 && splitIdx < text.length - 2) {
      line = _PlaceParts(
        em: MediaQuery.textScalerOf(context).scale(style.fontSize!),
        city: Text(
          text.substring(0, splitIdx),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textWidthBasis: TextWidthBasis.longestLine,
          style: style,
        ),
        country: Text(
          text.substring(splitIdx),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textWidthBasis: TextWidthBasis.longestLine,
          style: style,
        ),
        full: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
    } else {
      line = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 1), child: line);
  }
}

class _PlaceParts extends MultiChildRenderObjectWidget {
  _PlaceParts(
      {required this.em,
      required Widget city,
      required Widget country,
      required Widget full})
      : super(children: <Widget>[city, country, full]);

  final double em;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPlaceParts(em, Directionality.of(context));

  @override
  void updateRenderObject(
      BuildContext context, _RenderPlaceParts renderObject) {
    renderObject
      ..em = em
      ..textDirection = Directionality.of(context);
  }
}

class _PlacePartsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPlaceParts extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PlacePartsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PlacePartsParentData> {
  _RenderPlaceParts(this._em, this._textDirection);

  double _em;
  set em(double value) {
    if (value == _em) return;
    _em = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  RenderBox get _city => firstChild!;
  RenderBox get _country => childAfter(_city)!;
  RenderBox get _full => lastChild!;

  bool _whole = false;

  _PlacePartsParentData _pd(RenderBox child) =>
      child.parentData! as _PlacePartsParentData;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PlacePartsParentData) {
      child.parentData = _PlacePartsParentData();
    }
  }

  ({bool whole, double city, double country}) _plan(double maxWidth) {
    final city = _city.getMaxIntrinsicWidth(double.infinity);
    final country = _country.getMaxIntrinsicWidth(double.infinity);
    if (!maxWidth.isFinite) {
      return (whole: false, city: city, country: country);
    }
    if (maxWidth < _em * 6 && city + country > maxWidth) {
      return (whole: true, city: 0.0, country: 0.0);
    }
    final half = maxWidth / 2;
    var keep = math.min(city, half);
    if (city > half && country > half) {
      if (city <= maxWidth - _em * 2.5) {
        keep = city;
      } else if (country <= maxWidth - _em * 3) {
        keep = maxWidth - country;
      }
    }
    if (keep + country <= maxWidth) {
      return (
        whole: false,
        city: math.min(city, maxWidth - country),
        country: country,
      );
    }
    return (whole: false, city: keep, country: maxWidth - keep);
  }

  Size _measure(
    BoxConstraints c,
    Size Function(RenderBox child, BoxConstraints c) sizeOf, [
    void Function(bool whole, Size city, Size country)? place,
  ]) {
    final plan = _plan(c.maxWidth);
    const none = BoxConstraints.tightFor(width: 0, height: 0);
    final city =
        sizeOf(_city, plan.whole ? none : BoxConstraints(maxWidth: plan.city));
    final country = sizeOf(
        _country, plan.whole ? none : BoxConstraints(maxWidth: plan.country));
    final full =
        sizeOf(_full, plan.whole ? BoxConstraints(maxWidth: c.maxWidth) : none);
    place?.call(plan.whole, city, country);
    if (plan.whole) return c.constrain(full);
    return c.constrain(Size(
      city.width + country.width,
      math.max(city.height, country.height),
    ));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _measure(constraints, (child, c) => child.getDryLayout(c));

  @override
  void performLayout() {
    size = _measure(constraints, (child, c) {
      child.layout(c, parentUsesSize: true);
      return child.size;
    }, (whole, city, country) {
      _whole = whole;
      final rtl = _textDirection == TextDirection.rtl;
      _pd(_city).offset = Offset(rtl ? country.width : 0, 0);
      _pd(_country).offset = Offset(rtl ? 0 : city.width, 0);
      _pd(_full).offset = Offset.zero;
    });
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _city.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _full.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
      _city.getMinIntrinsicHeight(width),
      _country.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
      _city.getMaxIntrinsicHeight(width),
      _country.getMaxIntrinsicHeight(width));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      (_whole ? _full : _city).getDistanceToActualBaseline(baseline);

  bool _shows(RenderObject child) => _whole == (child == _full);

  @override
  bool paintsChild(RenderBox child) => _shows(child);

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in getChildrenAsList()) {
      if (_shows(child)) {
        context.paintChild(child, offset + _pd(child).offset);
      }
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final child in getChildrenAsList()) {
      if (_shows(child)) visitor(child);
    }
  }
}

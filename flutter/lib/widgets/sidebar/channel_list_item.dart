import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_context_menu.dart';
import '../../features/channels/geohash_place_cache.dart';
import '../../features/settings/settings_helpers.dart';
import '../../models/channel.dart';
import '../nym_icons.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_row_menu_button.dart';

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
  });

  final ChannelEntry entry;
  final bool active;
  final bool pinned;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  final bool mesh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final name = '#${entry.isGeohash ? entry.geohashKey : entry.channel}';
    final showPinned = pinned && !active;
    final location = entry.isGeohash ? geohashLocationLabel(entry.geohashKey) : '';

    final Color activeFill =
        c.isLight ? Colors.black.withValues(alpha: 0.06) : c.primaryA(0.10);
    // Hover loses to active but beats pinned, following the CSS cascade order.
    final Color hoverFill = c.isLight
        ? Colors.black.withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: 0.06);
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
      softWrap: true,
      style: TextStyle(
        color: c.text,
        fontSize: textSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );

    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameText,
        _ChannelLocationLine(
          geohash: entry.geohashKey,
          textSize: textSize,
        ),
      ],
    );

    return Padding(
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
                constraints: const BoxConstraints(minHeight: 36),
                padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 9, 12, 9),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: borderColor, width: 1),
                  boxShadow: glow,
                ),
                child: Row(
                  children: [
                    if (mesh) ...[
                      NymSvgIcon(NymIcons.bluetooth,
                          size: 12, color: c.primary),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: location.isEmpty
                          ? nameBlock
                          : Tooltip(message: location, child: nameBlock),
                    ),
                    // The unread pill is the only channel badge in the PWA; geohash vs named is shown by the name.
                    if (unread > 0) ...[
                      const SizedBox(width: 5),
                      _UnreadPill(count: unread),
                    ],
                    // Hidden when there is no menu, so it never appears as a dead tap target.
                    if (buildChannelMenuActions(context, ref, entry)
                        .isNotEmpty) ...[
                      const SizedBox(width: 2),
                      SidebarRowMenuButton(
                        semanticLabel: 'Channel menu',
                        onShowMenu: (pos) => maybeShowChannelContextMenu(
                            context, ref, entry, pos),
                      ),
                    ],
                  ],
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
  }
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.bg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
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
    final style = TextStyle(
      color: c.textDim,
      fontSize: widget.textSize - 3,
      height: 1.25,
    );
    // Only the city half ellipsizes, so a narrow row keeps the country.
    final splitIdx = _place != null ? text.lastIndexOf(', ') : -1;
    final Widget line;
    if (splitIdx > 0 && splitIdx < text.length - 2) {
      line = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text.substring(0, splitIdx),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Text(text.substring(splitIdx), maxLines: 1, style: style),
        ],
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

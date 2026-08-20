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

/// The grey "pinned/favorited" tint the PWA paints on a `.channel-item.pinned`
/// row when it is not the active channel (`rgba(150,150,160,…)`,
/// styles-shell.css:348-366).
const Color _pinnedGrey = Color(0xFF9696A0); // rgb(150,150,160)

/// A single channel row in the sidebar PUBLIC CHANNELS list.
///
/// Mirrors `.channel-item` (docs/specs/02 §5.3): padding 9/12, margin 2/4,
/// radius rxs, min-height 36, 1px transparent border; active state gets a
/// primary@10 fill, primary@20 border, glow, and a 3px left accent bar. A
/// favorited (pinned) row that is not active gets a grey fill/border/glow + a
/// grey accent bar instead. Unread count renders as a pill badge — the PWA's
/// ONLY channel badge.
///
/// A 500ms press-and-hold (mouse primary button or touch — the PWA binds no
/// `contextmenu` handler on the sidebar) opens the `.quick-context-menu`
/// (Favorite/Hide/Block) at the press point — see [SidebarRowGestures] /
/// [maybeShowChannelContextMenu].
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

  /// True when this channel is Bluetooth-mesh-backed — shows a small glyph.
  final bool mesh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final name = '#${entry.isGeohash ? entry.geohash : entry.channel}';
    // `.channel-item.pinned:not(.active)` paints the grey treatment; the active
    // state always wins.
    final showPinned = pinned && !active;
    // Geohash rows get a `title="{getGeohashLocation(geohash)}"` hover tooltip.
    final location = entry.isGeohash ? geohashLocationLabel(entry.geohash) : '';

    // `.channel-item.active` fill is primary@0.10 + a primary@0.05 glow (dark);
    // `body.light-mode` neutralises it to black@0.06 with `box-shadow:none`
    // (styles-themes-responsive.css:1139), keeping the primary@0.20 border +
    // primary accent bar. The pinned (grey) treatment has no light override.
    final Color activeFill =
        c.isLight ? Colors.black.withValues(alpha: 0.06) : c.primaryA(0.10);
    // `@media (hover:hover)` row hover (styles-shell.css:368-374): explicit
    // white@0.06 fill (light: black@0.04, styles-themes-responsive.css:1132)
    // that loses to `.active` but WINS over `.pinned` (the hover rule follows
    // `.pinned` in the stylesheet), plus a padding-left 12→14 content shift.
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
      // `.channel-name`: white-space:normal; overflow-wrap:break-word → wraps.
      softWrap: true,
      style: TextStyle(
        color: c.text,
        fontSize: textSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );

    // Name plus the location line beneath it (`.channel-sub`).
    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameText,
        _ChannelLocationLine(
          geohash: entry.isGeohash ? entry.geohash : '',
          textSize: textSize,
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      // The PWA's 500ms press-and-hold (mouse button 0 / touch, 10px move
      // cancel) opens the quick menu at the press point and swallows the
      // following tap; right-click deliberately does nothing
      // (sidebar-sections.js:239-303). Hover paints the explicit overlay +
      // 2px indent below.
      child: SidebarRowGestures(
        onTap: onTap,
        onShowMenu: (pos) =>
            maybeShowChannelContextMenu(context, ref, entry, pos),
        builder: (context, hovered) {
          // Fill priority mirrors the cascade: `.active` > `:hover` >
          // `.pinned` > transparent.
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
                // `:hover { padding-left: 14px }` (rest 12px).
                padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 9, 12, 9),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: borderColor, width: 1),
                  // `.channel-item.active`: box-shadow 0 0 12px primary@5%
                  // (grey@5% when pinned-not-active).
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
                      // `.channel-name` inherits `--text` weight normal even
                      // when active (active changes bg/border/bar only).
                      child: location.isEmpty
                          ? nameBlock
                          : Tooltip(message: location, child: nameBlock),
                    ),
                    // PWA `.channel-badges` only ever contains the unread
                    // pill. `.std-badge` / `.geohash-badge` are DEAD CSS —
                    // never emitted by channels.js/pms.js/groups.js. Geohash
                    // vs standard channels are distinguished by the name only.
                    // `.channel-badges { margin-left: 5px }` sets the gap.
                    if (unread > 0) ...[
                      const SizedBox(width: 5),
                      _UnreadPill(count: unread),
                    ],
                    // Same menu the hold opens. Suppressed where there would
                    // be no menu to open, so the control never appears as a
                    // dead tap target.
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
                          // Active bar is `--primary`; the pinned-not-active bar
                          // is `var(--text-dim)` (styles-shell.css:355-366).
                          color: active ? c.primary : c.textDim,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                          // `::before` accent bar glow: 0 0 8px primary@40%
                          // when active; 0 0 8px rgba(150,150,160,0.3) on the
                          // grey pinned bar.
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

/// `.unread-badge`: bg primary, text bg-color, pill, 10px weight 600, caps 99+.
class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.unread-badge`: min-width 3ch (content-box) + 7px h-padding ≈ 30px.
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

/// The dim location line under a sidebar channel name: the reverse-geocoded
/// place for a geohash channel, "Not a geohash" for a named one — the same
/// information the channel header carries.
///
/// A geohash paints its decoded coordinates immediately (local, no network) and
/// upgrades in place when the queued lookup lands, so the row is never empty and
/// never sits on a spinner. Resolution goes through [GeohashPlaceCache], which
/// persists and rate-limits; a place already cached costs no request at all.
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
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prime();
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is the natural moment to retry a name that
    // failed earlier, including one the backoff has given up on.
    if (state == AppLifecycleState.resumed && _place == null) {
      _prime(force: true);
    }
  }

  @override
  void didUpdateWidget(covariant _ChannelLocationLine old) {
    super.didUpdateWidget(old);
    if (old.geohash != widget.geohash) {
      _place = null;
      _retry?.cancel();
      _prime();
    }
  }

  void _prime({bool force = false}) {
    final gh = widget.geohash;
    if (gh.isEmpty) return;
    final cache = ref.read(geohashPlaceCacheProvider);
    final hit = cache.cached(gh);
    if (hit != null) {
      _place = hit;
      return;
    }
    cache.resolve(gh, force: force).then((place) {
      if (!mounted || widget.geohash != gh) return;
      if (place.isNotEmpty) {
        setState(() => _place = place);
        return;
      }
      // Missed. Nothing else re-triggers a lookup, so the row schedules its
      // own retry — otherwise it keeps the coordinates until the sidebar
      // happens to rebuild.
      _scheduleRetry(cache, gh);
    });
  }

  void _scheduleRetry(GeohashPlaceCache cache, String gh) {
    _retry?.cancel();
    final at = cache.retryAt(gh);
    if (at == null) return; // accepted as having no name
    final wait = at.difference(DateTime.now());
    _retry = Timer(wait.isNegative ? const Duration(seconds: 1) : wait, () {
      if (mounted && widget.geohash == gh && _place == null) _prime();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final gh = widget.geohash;
    final text =
        gh.isEmpty ? 'Not a geohash' : (_place ?? geohashLocationLabel(gh));
    if (text.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(
      color: c.textDim,
      fontSize: widget.textSize - 3,
      height: 1.25,
    );
    // Same split as the channel header (chat_pane.dart `_locationLine`): the
    // city half is the only part allowed to ellipsize, so a narrow sidebar
    // renders "Long City Na…, Country" instead of dropping the country. Only
    // a resolved place name has the "City, Country" shape — raw coordinates
    // and 'Not a geohash' stay a single run.
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

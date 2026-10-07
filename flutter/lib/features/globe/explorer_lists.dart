import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'geo_explore.dart';

enum GeoListTab { active, nearby, saved }

String geoWindowLabel(int hours) => switch (hours) {
      1 => tr('Last hour'),
      168 => tr('Last 7 days'),
      _ => tr('Last 24 hours'),
    };

String geoWindowShort(int hours) => switch (hours) {
      1 => tr('1h'),
      168 => tr('7d'),
      _ => tr('24h'),
    };

class GeoWindowControl extends StatelessWidget {
  const GeoWindowControl({
    super.key,
    required this.hours,
    required this.onChanged,
    this.radio = false,
  });

  final int hours;
  final void Function(int hours) onChanged;
  final bool radio;

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    return Semantics(
      label: tr('Activity window'),
      container: true,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: nym.glassBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in kGeoWindowOptions)
              Semantics(
                button: radio ? null : true,
                selected: radio ? null : h == hours,
                checked: radio ? h == hours : null,
                inMutuallyExclusiveGroup: radio ? true : null,
                onTap: radio ? () => onChanged(h) : null,
                label: geoWindowLabel(h),
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('geo-window-$h'),
                  onTap: () => onChanged(h),
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    alignment: Alignment.center,
                    color: h == hours ? nym.primaryA(0.18) : Colors.transparent,
                    child: Text(
                      geoWindowShort(h),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: h == hours ? nym.primary : nym.textDim,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GeoRoomLists extends StatelessWidget {
  const GeoRoomLists({
    super.key,
    required this.tab,
    required this.onTab,
    required this.active,
    required this.saved,
    required this.location,
    required this.windowHours,
    required this.onWindow,
    required this.placeLabel,
    required this.onOpen,
  });

  final GeoListTab tab;
  final void Function(GeoListTab tab) onTab;
  final List<GeoActivity> active;
  final List<GeoActivity> saved;
  final ({double lat, double lng})? location;
  final int windowHours;
  final void Function(int hours) onWindow;
  final String Function(String geohash) placeLabel;
  final void Function(String geohash) onOpen;

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final t in GeoListTab.values) Expanded(child: _tab(t, nym)),
          ],
        ),
        Divider(height: 1, color: nym.glassBorder),
        Expanded(child: _body(context, nym)),
      ],
    );
  }

  String _tabLabel(GeoListTab t) => switch (t) {
        GeoListTab.active => tr('Active now'),
        GeoListTab.nearby => tr('Nearby'),
        GeoListTab.saved => tr('Saved'),
      };

  Widget _tab(GeoListTab t, NymColors nym) {
    final on = t == tab;
    return Semantics(
      button: true,
      selected: on,
      label: _tabLabel(t),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('geo-tab-${t.name}'),
        onTap: () => onTab(t),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: on ? nym.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            _tabLabel(t),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? nym.primary : nym.textDim,
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(String title, String body, NymColors nym) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 13,
                    color: nym.text,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(body, style: TextStyle(fontSize: 12, color: nym.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, NymColors nym) {
    switch (tab) {
      case GeoListTab.active:
        final rows = rankGeoActive(active);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      geoWindowLabel(windowHours),
                      style: TextStyle(fontSize: 11, color: nym.textDim),
                    ),
                  ),
                  GeoWindowControl(hours: windowHours, onChanged: onWindow),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? _empty(tr('No active rooms'),
                      tr('Nothing was posted in this window.'), nym)
                  : _list([for (final r in rows) (r, null)], nym),
            ),
          ],
        );
      case GeoListTab.nearby:
        if (location == null) {
          return _empty(
            tr('Location is off'),
            tr('Turn on "Sort by proximity" in Settings to list rooms near you. Distances are worked out on this device and your location is never sent.'),
            nym,
          );
        }
        final rows = rankGeoNearby([...active, ...saved.where((s) => !active.any((a) => a.geohash == s.geohash))], location);
        if (rows.isEmpty) {
          return _empty(tr('No rooms yet'),
              tr('No active or saved rooms to measure.'), nym);
        }
        return _list([for (final r in rows) (r.item, r.distanceKm)], nym);
      case GeoListTab.saved:
        if (saved.isEmpty) {
          return _empty(tr('No saved places'),
              tr('Star a cell to save it here.'), nym);
        }
        return _list([for (final s in saved) (s, null)], nym);
    }
  }

  Widget _list(List<(GeoActivity, double?)> rows, NymColors nym) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (c, km) = rows[i];
        final distKm = km ??
            (location == null
                ? null
                : haversineKm(location!.lat, location!.lng, c.lat, c.lng));
        return _row(c, distKm, nym);
      },
    );
  }

  Widget _row(GeoActivity c, double? km, NymColors nym) {
    final place = placeLabel(c.geohash);
    final activity = c.messages == 1
        ? tr('1 message')
        : tr('{n} messages', {'n': c.messages});
    final dist = km == null
        ? null
        : tr('{d} away', {'d': formatGeoDistanceKm(km)});
    final parts = [
      '#${c.geohash}',
      if (place.isNotEmpty) place,
      ?dist,
      activity,
    ];
    return Semantics(
      button: true,
      label: parts.join(', '),
      hint: tr('Shows this room on the map'),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('geo-row-${c.geohash}'),
        onTap: () => onOpen(c.geohash),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: nym.glassBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '#${c.geohash}',
                      style: TextStyle(
                        fontSize: 13,
                        color: nym.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (place.isNotEmpty)
                      Text(
                        place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: nym.text),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(activity,
                      style: TextStyle(fontSize: 11, color: nym.text)),
                  if (dist != null)
                    Text(dist,
                        style: TextStyle(fontSize: 11, color: nym.textDim)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/globe/geo_projection.dart';
import 'package:nym_bar/features/globe/geohash_explorer.dart';
import 'package:nym_bar/features/globe/topojson.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

void main() {
  group('TopoJSON decoder', () {
    test('decodes countries-110m.json into plausible country rings', () {
      // Read straight from disk (no asset bundle needed for the pure decoder).
      final file = File('assets/data/countries-110m.json');
      expect(file.existsSync(), isTrue,
          reason: 'bundled world map asset must exist');
      final jsonStr = file.readAsStringSync();

      final feats = decodeWorldTopoJson(jsonStr);

      // world-atlas countries-110m has ~177 countries.
      expect(feats.length, greaterThan(100));
      expect(feats.length, lessThan(300));

      // Sorted largest-area first.
      for (var i = 1; i < feats.length; i++) {
        expect(feats[i - 1].area, greaterThanOrEqualTo(feats[i].area));
      }

      // Every vertex must be a valid lon/lat.
      var totalRings = 0;
      for (final f in feats) {
        for (final poly in f.polygons) {
          for (final ring in poly) {
            totalRings++;
            for (final pt in ring) {
              expect(pt[0], inInclusiveRange(-180.0, 180.0));
              expect(pt[1], inInclusiveRange(-90.0, 90.0));
            }
          }
        }
      }
      expect(totalRings, greaterThan(150));

      // At least one well-known country name decoded.
      expect(feats.any((f) => f.name.isNotEmpty), isTrue);
    });
  });

  group('Equirectangular projection', () {
    const size = Size(720, 360);

    test('(0,0) maps to the canvas center at zoom 1', () {
      const view = GeoView();
      final p = view.project(0, 0, size);
      expect(p.dx, closeTo(size.width / 2, 1e-6));
      expect(p.dy, closeTo(size.height / 2, 1e-6));
    });

    test('(180,90) reaches the top-right corner-ish at zoom 1', () {
      const view = GeoView();
      // baseScale for 720x360 = max(2, 2) = 2 px/deg. 180deg*2 = 360 = half W.
      final p = view.project(180, 90, size);
      expect(p.dx, closeTo(size.width, 1e-6)); // 360 + 360
      expect(p.dy, closeTo(0, 1e-6)); // 180 - 180
    });

    test('project/unproject round-trips', () {
      const view = GeoView(cx: 12.3, cy: -45.6, zoom: 3.5);
      for (final ll in const [
        [0.0, 0.0],
        [120.0, 33.0],
        [-77.0, -12.0],
      ]) {
        final p = view.project(ll[0], ll[1], size);
        final back = view.unproject(p.dx, p.dy, size);
        expect(back.lng, closeTo(ll[0], 1e-6));
        expect(back.lat, closeTo(ll[1], 1e-6));
      }
    });

    test('geohash grid precision rises with zoom', () {
      const small = GeoView(zoom: 1);
      const big = GeoView(zoom: 16);
      expect(
        computeGridPrecision(big, size),
        greaterThanOrEqualTo(computeGridPrecision(small, size)),
      );
    });

    test('geohashBounds decodes a known cell', () {
      final b = geohashBounds('9q8y'); // near San Francisco
      expect(b, isNotNull);
      final cy = (b!.latLo + b.latHi) / 2;
      final cx = (b.lngLo + b.lngHi) / 2;
      expect(cy, closeTo(37.75, 0.2));
      expect(cx, closeTo(-122.43, 0.2));
    });
  });

  group('GeohashExplorer widget', () {
    testWidgets('renders without throwing', (tester) async {
      // The explorer now reads settingsProvider (→ keyValueStoreProvider) and
      // appStateProvider, so the smoke test must supply the key/value store the
      // same way the rest of the suite does.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[colors],
            ),
            home: const GeohashExplorer(),
          ),
        ),
      );
      // Let the async asset/decode microtasks settle (best-effort).
      await tester.pump();

      expect(find.text('GEOHASH EXPLORER'), findsOneWidget);
      expect(find.byType(GeohashExplorer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

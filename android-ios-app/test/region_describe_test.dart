// `describeRegion` must name a place the geocoder cannot: some geohash cells
// genuinely have no address (open ocean, the Antarctic plateau), and raw
// coordinates told the user nothing. These run against the REAL bundled map
// data, so they also guard the Natural Earth quirk the implementation works
// around — its Antarctica ring is clipped at ~-85.6 and never closes around the
// pole, so plain point-in-polygon calls the whole polar cap "not land".
//
// The expectations are duplicated in the PWA's `npm run test:geo-region`; the
// two implementations must agree.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/globe/topojson.dart';

void main() {
  late List<GeoFeature> world;

  setUpAll(() {
    world = decodeWorldTopoJson(
        File('assets/data/countries-110m.json').readAsStringSync());
  });

  test('the bundled world data decodes', () {
    expect(world.length, greaterThan(150));
    expect(world.any((f) => f.name == 'Antarctica'), isTrue);
  });

  group('on land, the country', () {
    const cases = {
      'Paris': [48.85, 2.35, 'France'],
      'Tokyo': [35.68, 139.69, 'Japan'],
      'Sao Paulo': [-23.55, -46.63, 'Brazil'],
      'Greenland interior': [72.0, -40.0, 'Greenland'],
    };
    cases.forEach((label, v) {
      test(label, () {
        expect(describeRegion(world, v[0] as double, v[1] as double), v[2]);
      });
    });
  });

  group('the polar caps', () {
    test('the South Pole is Antarctica, not a sea', () {
      // Below Natural Earth's clip line, so point-in-polygon alone says
      // "not land" for every longitude here.
      expect(describeRegion(world, -90, 0), 'Antarctica');
      expect(describeRegion(world, -87.19, -118.13), 'Antarctica');
    });

    test('the clipped cap is named at every longitude', () {
      for (var lng = -180.0; lng < 180; lng += 30) {
        expect(describeRegion(world, -87, lng), 'Antarctica',
            reason: 'lng $lng fell out of the polar cap');
      }
    });

    test('the North Pole is open Arctic Ocean', () {
      expect(describeRegion(world, 90, 0), 'Arctic Ocean');
    });
  });

  group('at sea, what it is near', () {
    test('a cell centred in the Irish Sea names Ireland', () {
      expect(describeRegion(world, 53.44, -5.63), 'Off the coast of Ireland');
    });
    test('the Gulf of Mexico is coastal, not open ocean', () {
      expect(describeRegion(world, 25.31, -84.38), startsWith('Off the coast of'));
    });
    test('the mid-Pacific is open ocean', () {
      expect(describeRegion(world, 0, -150), 'Open ocean');
    });
    test('a coastal Antarctic point names the coast, not the ocean', () {
      expect(describeRegion(world, -77.85, 166.67), 'Off the coast of Antarctica');
    });
  });

  test('it never returns coordinates, whatever it is given', () {
    for (var lat = -90.0; lat <= 90; lat += 15) {
      for (var lng = -180.0; lng < 180; lng += 45) {
        final d = describeRegion(world, lat, lng);
        expect(d, isNotEmpty, reason: 'no description at $lat,$lng');
        expect(d, isNot(contains('°')), reason: 'coordinates leaked at $lat,$lng');
      }
    }
  });

  test('an empty world yields nothing rather than a wrong guess', () {
    expect(describeRegion(const [], 0, 0), '');
  });
}

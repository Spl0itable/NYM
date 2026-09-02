/// Every icon in [NymIcons] has to actually draw.
///
/// A malformed one is silent: flutter_svg logs and renders nothing, so the
/// button keeps its tap target and its tooltip and simply looks empty — which
/// reads as "the button is gone", not as "the icon is wrong". The mesh ping
/// button is the case that prompted this (its glyph changed to a radar sweep),
/// but nothing about the risk is specific to that one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:nym_bar/widgets/nym_icons.dart';

/// Every `static const String` on [NymIcons], by name.
const Map<String, String> _icons = <String, String>{
  'radar': NymIcons.radar,
  'shareNodes': NymIcons.shareNodes,
  'lock': NymIcons.lock,
  'phone': NymIcons.phone,
  'addReaction': NymIcons.addReaction,
};

/// An SVG with nothing in it, as the floor a real glyph has to beat: the
/// compiled form of a shape-less document is the shortest output the encoder
/// can produce, so anything that draws is strictly longer.
const String _empty = '<svg viewBox="0 0 24 24"></svg>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('every NymIcons glyph compiles to something that draws', () {
    late int floor;
    setUpAll(() async {
      floor = (await const SvgStringLoader(_empty).loadBytes(null))
          .lengthInBytes;
    });

    for (final entry in _icons.entries) {
      test('${entry.key}', () async {
        final bytes = await SvgStringLoader(entry.value).loadBytes(null);
        expect(bytes.lengthInBytes, greaterThan(floor),
            reason: '${entry.key} compiled to nothing drawable — the button '
                'keeps its tap target and looks empty');
      });
    }
  });

  testWidgets('the mesh ping radar renders through NymSvgIcon', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: NymSvgIcon(NymIcons.radar, size: 16, color: Colors.white),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

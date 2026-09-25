import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/widgets/common/brand_buttons.dart';

NymColors _colors(Brightness brightness) => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: brightness,
      solidUi: true,
    );

Widget _host(Brightness brightness, Widget child) => MaterialApp(
      theme: buildNymThemeData(_colors(brightness)),
      home: Scaffold(body: Center(child: child)),
    );

Material _capsule(WidgetTester tester, Finder button) => tester.widget<Material>(
    find.descendant(of: button, matching: find.byType(Material)).first);

Text _label(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text));

void main() {
  group('branded buttons', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;

      testWidgets('Apple follows the HIG in ${brightness.name}', (tester) async {
        var taps = 0;
        await tester.pumpWidget(
            _host(brightness, AppleButton(onPressed: () => taps++)));
        final button = find.byType(AppleButton);
        expect(find.text('Continue with Apple'), findsOneWidget);
        expect(_capsule(tester, button).color,
            dark ? Colors.white : Colors.black);
        expect(_capsule(tester, button).shape, isA<StadiumBorder>());
        expect(_label(tester, 'Continue with Apple').style!.color,
            dark ? Colors.black : Colors.white);
        expect(_label(tester, 'Continue with Apple').style!.fontSize, 15);
        expect(_label(tester, 'Continue with Apple').style!.fontWeight,
            FontWeight.w500);
        expect(find.byType(AppleMark), findsOneWidget);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
        expect(find.bySemanticsLabel('Continue with Apple'), findsOneWidget);
        await tester.tap(button);
        expect(taps, 1);
      });

      testWidgets('Google uses its brand colors in ${brightness.name}',
          (tester) async {
        var taps = 0;
        await tester.pumpWidget(
            _host(brightness, GoogleButton(onPressed: () => taps++)));
        final button = find.byType(GoogleButton);
        final capsule = _capsule(tester, button);
        expect(capsule.color,
            dark ? const Color(0xFF131314) : const Color(0xFFFFFFFF));
        expect((capsule.shape! as StadiumBorder).side.color,
            dark ? const Color(0xFF8E918F) : const Color(0xFF747775));
        expect(_label(tester, 'Continue with Google').style!.color,
            dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F));
        expect(tester.getSize(find.byType(GoogleMark)), const Size(20, 20));
        expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
        await tester.tap(button);
        expect(taps, 1);
      });

      testWidgets('the passkey button takes the theme in ${brightness.name}',
          (tester) async {
        var taps = 0;
        await tester.pumpWidget(_host(
            brightness,
            PasskeyButton(
                label: 'Continue with a passkey', onPressed: () => taps++)));
        final button = find.byType(PasskeyButton);
        final c = _colors(brightness);
        expect(_capsule(tester, button).color, c.bgSecondary);
        expect(_label(tester, 'Continue with a passkey').style!.color, c.inputText);
        expect((_capsule(tester, button).shape! as StadiumBorder).side.width, 1);
        expect(find.byType(PasskeyMark), findsOneWidget);
        expect(find.bySemanticsLabel('Continue with a passkey'), findsOneWidget);
        await tester.tap(button);
        expect(taps, 1);
      });
    }

    testWidgets('a disabled button does not fire', (tester) async {
      await tester.pumpWidget(
          _host(Brightness.dark, const GoogleButton(onPressed: null)));
      await tester.tap(find.byType(GoogleButton));
      expect(tester.getSemantics(find.bySemanticsLabel('Continue with Google')),
          isNot(matchesSemantics(isEnabled: true)));
    });
  });
}

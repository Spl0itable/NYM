import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/reactions/reactors_modal.dart';
import 'package:nym_bar/widgets/anchored_popup.dart';

void main() {
  const screen = Size(390, 844);
  const insets = EdgeInsets.only(top: 47, bottom: 34);
  const child = Size(240, 200);

  Offset place(Rect anchor,
          {PopupAlign align = PopupAlign.start, bool preferAbove = true}) =>
      AnchoredPopupLayout(
        anchor: anchor,
        insets: insets,
        align: align,
        preferAbove: preferAbove,
      ).getPositionForChild(screen, child);

  group('an anchored popup stays inside the safe area', () {
    test('above the anchor when there is room', () {
      final p = place(const Rect.fromLTWH(20, 500, 60, 20));
      expect(p.dy, 500 - 6 - child.height);
      expect(p.dx, 20);
    });

    test('below the anchor when the top is too close', () {
      final p = place(const Rect.fromLTWH(20, 120, 60, 20));
      expect(p.dy, 120 + 20 + 6);
    });

    test('an anchor at the foot of the screen never runs under the edge', () {
      final p = place(const Rect.fromLTWH(20, 810, 60, 20), preferAbove: false);
      expect(p.dy + child.height, lessThanOrEqualTo(844 - 34 - 10));
      expect(p.dy, 844 - 34 - 10 - child.height);
    });

    test('an anchor under the notch opens below it, not into it', () {
      final p = place(const Rect.fromLTWH(20, 40, 60, 20));
      expect(p.dy, greaterThanOrEqualTo(47 + 10));
    });

    test('right-aligned near the left edge, left-aligned near the right edge',
        () {
      final end = place(const Rect.fromLTWH(4, 500, 30, 20),
          align: PopupAlign.end);
      expect(end.dx, 10);
      final start = place(const Rect.fromLTWH(370, 500, 30, 20));
      expect(start.dx + child.width, lessThanOrEqualTo(390 - 10));
    });

    test('a child taller than the safe box is constrained to it', () {
      final c = AnchoredPopupLayout(anchor: Rect.zero, insets: insets)
          .getConstraintsForChild(BoxConstraints.tight(screen));
      expect(c.maxHeight, 844 - 47 - 34 - 20);
      expect(c.maxWidth, 390 - 20);
    });
  });

  group('a popup placed at a point', () {
    test('is lifted above the press but kept below the status bar', () {
      final p = PointPopupLayout(
        anchor: const Offset(200, 60),
        insets: insets,
        offset: const Offset(0, -55),
        centerX: true,
      ).getPositionForChild(screen, child);
      expect(p.dy, 47 + 10);
      expect(p.dx, 200 - child.width / 2);
    });

    test('is pushed up from the home indicator', () {
      final p = PointPopupLayout(anchor: const Offset(300, 800), insets: insets)
          .getPositionForChild(screen, child);
      expect(p.dy + child.height, 844 - 34 - 10);
      expect(p.dx + child.width, 390 - 10);
    });
  });

  group('on a phone with a notch and a home indicator', () {
    Future<void> pumpApp(WidgetTester tester, Widget body) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(padding: const EdgeInsets.only(top: 47, bottom: 34)),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      ));
      await tester.pump();
    }

    testWidgets('a reactors modal from a badge at the foot stays on screen',
        (tester) async {
      await pumpApp(
        tester,
        Stack(children: [
          Positioned(
            left: 300,
            top: 820,
            child: Builder(builder: (ctx) {
              return GestureDetector(
                key: const ValueKey('badge'),
                behavior: HitTestBehavior.opaque,
                onTap: () => showReactorsModal(
                  ctx,
                  anchorRect: const Rect.fromLTWH(300, 820, 40, 20),
                  emoji: '🔥',
                  reactors: [
                    for (var i = 0; i < 12; i++)
                      ReactorEntry(pubkey: 'p$i', nym: 'nym$i'),
                  ],
                ),
                child: const SizedBox(width: 40, height: 20),
              );
            }),
          ),
        ]),
      );
      await tester.tap(find.byKey(const ValueKey('badge')));
      await tester.pumpAndSettle();
      final modal = tester.getRect(find.byType(ReactorsModal));
      expect(modal.bottom, lessThanOrEqualTo(844 - 34 - 10));
      expect(modal.right, lessThanOrEqualTo(390 - 10));
      expect(modal.top, greaterThanOrEqualTo(47 + 10));
    });

    testWidgets('a reactors modal from a badge under the notch opens below it',
        (tester) async {
      await pumpApp(
        tester,
        Builder(builder: (ctx) {
          return GestureDetector(
            key: const ValueKey('badge'),
            behavior: HitTestBehavior.opaque,
            onTap: () => showReactorsModal(
              ctx,
              anchorRect: const Rect.fromLTWH(10, 50, 40, 20),
              emoji: '🔥',
              reactors: [ReactorEntry(pubkey: 'p', nym: 'nym')],
            ),
            child: const SizedBox(width: 40, height: 20),
          );
        }),
      );
      await tester.tap(find.byKey(const ValueKey('badge')));
      await tester.pumpAndSettle();
      final modal = tester.getRect(find.byType(ReactorsModal));
      expect(modal.top, 50 + 20 + 6);
      expect(modal.left, 10);
    });
  });
}

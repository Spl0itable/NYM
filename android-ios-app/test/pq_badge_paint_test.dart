// The badge's orbit is drawn through a rotate-about-a-point matrix. It was
// built with Matrix4.translateByDouble, which does not exist on the oldest SDK
// pubspec allows (^3.6.0) -- `flutter analyze` passed locally on a newer one
// and the iOS release build failed. The mutating translate/scale helpers are
// the opposite trap: deprecated on current SDKs.
//
// So: assert the transform by BEHAVIOUR, which is stable whichever spelling is
// used, and keep a guard on the APIs that break one end of the range.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/chat/crypto_pq_badge.dart';

/// The transform the painter composes, spelled exactly as the widget does.
Matrix4 orbitTransform() =>
    Matrix4.translationValues(12.0, 12.0, 0.0) *
    Matrix4.rotationZ(-32 * 3.1415926535897932 / 180) *
    Matrix4.translationValues(-12.0, -12.0, 0.0);

Offset apply(Matrix4 m, Offset p) {
  final s = m.storage;
  return Offset(s[0] * p.dx + s[4] * p.dy + s[12],
      s[1] * p.dx + s[5] * p.dy + s[13]);
}

void main() {
  group('orbit transform', () {
    final m = orbitTransform();
    const center = Offset(12, 12);

    test('the centre of rotation is a fixed point', () {
      final out = apply(m, center);
      expect((out - center).distance, lessThan(1e-9));
    });

    test('distance from the centre is preserved', () {
      const p = Offset(18.2, 12);
      final out = apply(m, p);
      expect(((out - center).distance - (p - center).distance).abs(),
          lessThan(1e-9));
    });

    test('it rotates by 32 degrees, in the direction the SVG does', () {
      const p = Offset(18.2, 12); // due right of centre
      final out = apply(m, p) - center;
      // Screen coordinates: y grows downward, so a -32 degree rotateZ carries
      // a rightward point UPWARD.
      expect(out.dy, lessThan(0));
      final degrees = math.atan2(out.dy, out.dx) * 180 / math.pi;
      expect(degrees, closeTo(-32, 1e-6));
    });
  });

  // What actually broke the build. Neither spelling works across the whole
  // range pubspec declares, and analyze only ever sees one end of it.
  test('no source file uses a vector_math API the minimum SDK lacks', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final api in const [
        'translateByDouble', 'translateByVector3', 'translateByVector4',
        'scaleByDouble', 'scaleByVector3', 'scaleByVector4',
      ]) {
        if (src.contains(api)) offenders.add('${f.path}: $api');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these exist only on newer SDKs than pubspec allows; compose '
            'with Matrix4.translationValues / Matrix4.rotationZ instead');
  });

  testWidgets('every badge state paints', (tester) async {
    for (final state in PqBadgeState.values) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: CryptoPqBadge(state: state))),
      ));
      expect(tester.takeException(), isNull, reason: 'state $state threw');
    }
  });
}

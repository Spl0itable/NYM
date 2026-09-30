import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'localization_service.dart';

String creditFigure(num? value) {
  if (value == null) return '\u2026';
  final n = value.toDouble();
  if (n == n.roundToDouble()) return n.round().toString();
  if (n > 0 && n < 0.01) return '<0.01';
  var two = n.toStringAsFixed(2);
  while (two.endsWith('0')) {
    two = two.substring(0, two.length - 1);
  }
  if (two.endsWith('.')) two = two.substring(0, two.length - 1);
  return two;
}

/// Localizes static UI text, falling back to English; [args] fills `{name}` placeholders after translation.
String tr(String source, [Map<String, Object?>? args]) =>
    LocalizationService.instance.translate(source, args);

/// String sugar: `'Settings'.tr()` / `'Hi {name}'.tr({'name': n})`.
extension TrString on String {
  String tr([Map<String, Object?>? args]) =>
      LocalizationService.instance.translate(this, args);
}

/// Bumped when UI translations are cached or the language changes, so the root rebuilds and re-reads [tr].
final i18nVersionProvider = StateProvider<int>((ref) => 0);

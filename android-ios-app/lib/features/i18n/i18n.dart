import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'localization_service.dart';

/// The one call every widget uses to localize static UI text.
///
/// Returns [source] localized into the active UI language, or [source] itself
/// (English) when no language is selected or the translation hasn't cached yet.
/// [args] fills `{name}` placeholders **after** translation, so a template like
/// `tr('Step {n} of {total}', {'n': i + 1, 'total': count})` caches once per
/// language regardless of the numbers.
///
/// It is a bare top-level function (delegating to [LocalizationService]) so it
/// can be dropped into `StatelessWidget`/`State` build methods without
/// threading `ref`/`context`; reactivity comes from the root widget rebuilding
/// on [i18nVersionProvider] when new translations land.
String tr(String source, [Map<String, Object?>? args]) =>
    LocalizationService.instance.translate(source, args);

/// String sugar: `'Settings'.tr()` / `'Hi {name}'.tr({'name': n})`.
extension TrString on String {
  String tr([Map<String, Object?>? args]) =>
      LocalizationService.instance.translate(this, args);
}

/// A monotonically-increasing counter bumped whenever a batch of UI-string
/// translations is cached (or the language changes). The root app widget
/// watches it so the entire widget tree rebuilds and re-reads [tr], swapping
/// English fallbacks for freshly cached translations.
final i18nVersionProvider = StateProvider<int>((ref) => 0);

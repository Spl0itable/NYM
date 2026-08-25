/// Translating a message then receiving another used to clear the translation:
/// the flag lived in MessageRow's State, and the lazy list disposes rows that
/// scroll away and rebuilds keyed children when a unit is inserted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/translate/translated_messages.dart';

void main() {
  late ProviderContainer c;
  TranslatedMessages get() => c.read(translatedMessagesProvider.notifier);
  Map<String, String?> state() => c.read(translatedMessagesProvider);

  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('a shown translation survives anything that rebuilds the row', () {
    get().show('m1');
    expect(get().isShown('m1'), isTrue);
    // Nothing about another message disturbs it.
    get().show('m2');
    expect(get().isShown('m1'), isTrue);
    expect(state().length, 2);
  });

  test('an untranslated message is not shown', () {
    expect(get().isShown('nope'), isFalse);
    expect(get().langFor('nope'), isNull);
  });

  test('the per-message language override is kept', () {
    get().show('m1', lang: 'fr');
    expect(get().langFor('m1'), 'fr');
    get().show('m2');
    expect(get().langFor('m2'), isNull,
        reason: 'null means "use the default target", not "no entry"');
    expect(get().isShown('m2'), isTrue);
  });

  test('re-showing with a new language replaces the override', () {
    get().show('m1', lang: 'fr');
    get().show('m1', lang: 'de');
    expect(get().langFor('m1'), 'de');
    expect(state().length, 1);
  });

  test('hide removes it', () {
    get().show('m1');
    get().hide('m1');
    expect(get().isShown('m1'), isFalse);
  });

  test('an empty id is ignored rather than stored', () {
    get().show('');
    expect(state(), isEmpty);
  });

  // A long session in a busy channel would otherwise grow one entry per
  // translated message for the life of the process.
  test('the map is bounded, evicting least-recently-shown', () {
    for (var i = 0; i < 520; i++) {
      get().show('m$i');
    }
    expect(state().length, lessThanOrEqualTo(500));
    expect(get().isShown('m519'), isTrue, reason: 'the newest is kept');
    expect(get().isShown('m0'), isFalse, reason: 'the oldest is evicted');
  });

  test('re-showing with no change does not churn state', () {
    get().show('m1');
    final before = state();
    get().show('m1');
    expect(identical(state(), before), isTrue,
        reason: 'a repeat tap must not emit and rebuild every row');
  });

  test('changing the language of an old entry makes it recent again', () {
    for (var i = 0; i < 400; i++) {
      get().show('m$i');
    }
    get().show('m0', lang: 'fr');
    for (var i = 400; i < 520; i++) {
      get().show('m$i');
    }
    expect(get().isShown('m0'), isTrue,
        reason: 're-inserted on a real change, so it outlives m1..m20');
    expect(get().isShown('m1'), isFalse);
  });
}

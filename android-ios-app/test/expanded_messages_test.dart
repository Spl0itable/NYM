/// Expanding a long message past its "Read more" clamp, then receiving another
/// message, used to snap it shut: the flag lived in the collapsible's own
/// State, and an arriving message can dispose or re-parent a still-visible row.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/expanded_messages.dart';

void main() {
  late ProviderContainer c;
  ExpandedMessages get() => c.read(expandedMessagesProvider.notifier);
  Set<String> state() => c.read(expandedMessagesProvider);

  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('an expanded body survives anything that rebuilds the row', () {
    get().expand('m1');
    expect(get().isExpanded('m1'), isTrue);
    // A message arriving is just another id being tracked.
    get().expand('m2');
    expect(get().isExpanded('m1'), isTrue);
    expect(state().length, 2);
  });

  test('an untouched message is collapsed', () {
    expect(get().isExpanded('nope'), isFalse);
  });

  test('a message body and its quote clamp independently', () {
    get().expand('m1');
    expect(get().isExpanded('m1#quote'), isFalse,
        reason: 'the quote inside m1 has its own toggle');
    get().expand('m1#quote');
    expect(get().isExpanded('m1'), isTrue);
    expect(get().isExpanded('m1#quote'), isTrue);
  });

  test('collapse removes it', () {
    get().expand('m1');
    get().collapse('m1');
    expect(get().isExpanded('m1'), isFalse);
  });

  test('toggle follows the flag', () {
    get().toggle('m1', expanded: true);
    expect(get().isExpanded('m1'), isTrue);
    get().toggle('m1', expanded: false);
    expect(get().isExpanded('m1'), isFalse);
  });

  test('an empty key is ignored rather than stored', () {
    get().expand('');
    expect(state(), isEmpty);
  });

  test('re-expanding does not churn state', () {
    get().expand('m1');
    final before = state();
    get().expand('m1');
    expect(identical(state(), before), isTrue,
        reason: 'a no-op must not emit and rebuild every row');
  });

  test('collapsing something never expanded does not churn state', () {
    final before = state();
    get().collapse('m1');
    expect(identical(state(), before), isTrue);
  });

  test('the set is bounded, evicting the oldest expansion', () {
    for (var i = 0; i < 520; i++) {
      get().expand('m$i');
    }
    expect(state().length, lessThanOrEqualTo(500));
    expect(get().isExpanded('m519'), isTrue, reason: 'the newest is kept');
    expect(get().isExpanded('m0'), isFalse, reason: 'the oldest is evicted');
  });

  test('clear drops everything', () {
    get().expand('m1');
    get().clear();
    expect(state(), isEmpty);
  });
}

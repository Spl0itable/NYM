/// Expanded "Read more" bodies, kept outside row State so lazy-list disposal and re-parenting don't lose them.
library;

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ExpandedMessages extends Notifier<Set<String>> {
  /// Bounded so a long session doesn't grow this forever.
  static const int _max = 500;

  @override
  Set<String> build() => const {};

  bool isExpanded(String key) => state.contains(key);

  void expand(String key) {
    if (key.isEmpty || state.contains(key)) return;
    final next = LinkedHashSet<String>.from(state)..add(key);
    while (next.length > _max) {
      next.remove(next.first);
    }
    state = next;
  }

  void collapse(String key) {
    if (!state.contains(key)) return;
    state = LinkedHashSet<String>.from(state)..remove(key);
  }

  void toggle(String key, {required bool expanded}) =>
      expanded ? expand(key) : collapse(key);

  void clear() => state = const {};
}

final expandedMessagesProvider =
    NotifierProvider<ExpandedMessages, Set<String>>(ExpandedMessages.new);

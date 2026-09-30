/// Per-message translate requests, kept outside row State so lazy-list disposal and re-parenting don't lose them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class TranslatedMessages extends Notifier<Map<String, String?>> {
  /// Bounded so a long session doesn't grow this forever.
  static const int _max = 500;

  @override
  Map<String, String?> build() => const {};

  bool isShown(String messageId) => state.containsKey(messageId);

  String? langFor(String messageId) => state[messageId];

  void show(String messageId, {String? lang}) {
    if (messageId.isEmpty) return;
    if (state[messageId] == lang && state.containsKey(messageId)) return;
    final next = Map<String, String?>.from(state);
    next.remove(messageId); // re-insert so eviction is least-recently-shown
    next[messageId] = lang;
    while (next.length > _max) {
      next.remove(next.keys.first);
    }
    state = next;
  }

  void hide(String messageId) {
    if (!state.containsKey(messageId)) return;
    state = Map<String, String?>.from(state)..remove(messageId);
  }

  void clear() => state = const {};
}

final translatedMessagesProvider =
    NotifierProvider<TranslatedMessages, Map<String, String?>>(
        TranslatedMessages.new);

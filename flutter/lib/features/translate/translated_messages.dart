/// Which messages the user asked to translate, and with what override.
///
/// This lived as `_showTranslation` in [MessageRow]'s State, which loses it in
/// two ways: the list is lazy, so a row scrolled out of view is disposed, and
/// the sliver rebuilds keyed children by index when a unit is inserted, so an
/// arriving message tore down still-visible rows. Either way the translation
/// vanished. Keyed by message id, it survives both.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class TranslatedMessages extends Notifier<Map<String, String?>> {
  /// Bounded: a long session in a busy channel would otherwise accumulate one
  /// entry per translated message for the life of the process.
  static const int _max = 500;

  @override
  Map<String, String?> build() => const {};

  bool isShown(String messageId) => state.containsKey(messageId);

  /// The per-message target-language override, or null for the default.
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

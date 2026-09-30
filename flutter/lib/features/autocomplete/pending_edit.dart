import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One-shot "edit this message" request written by the context menu and consumed by the composer.
class PendingEdit {
  const PendingEdit({required this.messageId, required this.content});

  final String messageId;

  final String content;
}

class PendingEditNotifier extends StateNotifier<PendingEdit?> {
  PendingEditNotifier() : super(null);

  void request({required String messageId, required String content}) =>
      state = PendingEdit(messageId: messageId, content: content);

  /// Clears the pending edit once applied or canceled.
  void consume() => state = null;
}

final pendingEditProvider =
    StateNotifierProvider<PendingEditNotifier, PendingEdit?>(
  (ref) => PendingEditNotifier(),
);

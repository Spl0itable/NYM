import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A one-shot "edit this message" request raised by the context menu and
/// consumed by the composer (mirrors the PWA's `startEditMessage` /
/// `pendingEdit`, messages.js:1861-1919).
///
/// The PWA's "Edit" loads the original content into the message input, shows an
/// amber "Editing message" chip above it, and applies the edit on the NEXT send
/// (`messages.js` send path checks `this.pendingEdit`). To reproduce that inline
/// flow without a modal — and without coupling the composer (this slice) to the
/// context-menu slice's `interaction_hooks.dart` — the context menu writes a
/// [PendingEdit] here and the composer reads + [consume]s it.
///
/// CROSS-FILE CONTRACT (context-menu slice): replace the modal edit prompt in
/// `context_menu_panel._edit` with
/// `ref.read(pendingEditProvider.notifier).request(messageId: …, content: …)`.
class PendingEdit {
  const PendingEdit({required this.messageId, required this.content});

  /// The id of the message being edited (channel event id / nym message id).
  final String messageId;

  /// The original content to seed the composer input with.
  final String content;
}

/// Holds the most-recent un-consumed edit request (or null).
class PendingEditNotifier extends StateNotifier<PendingEdit?> {
  PendingEditNotifier() : super(null);

  /// Request that the composer enter inline-edit mode for [messageId], seeding
  /// the input with [content] and showing the amber edit chip.
  void request({required String messageId, required String content}) =>
      state = PendingEdit(messageId: messageId, content: content);

  /// Clears the pending edit once the composer has applied it (or it was
  /// cancelled). Mirrors `cancelEditMessage`.
  void consume() => state = null;
}

/// The edit-request mailbox. The context menu writes; the composer reads.
final pendingEditProvider =
    StateNotifierProvider<PendingEditNotifier, PendingEdit?>(
  (ref) => PendingEditNotifier(),
);

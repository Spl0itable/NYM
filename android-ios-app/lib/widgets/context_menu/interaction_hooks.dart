import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';

/// Infers the `originalKind` (`'k'` tag) to attach to a reaction / zap targeting
/// [message], mirroring the PWA's reaction & zap kind inference
/// (reactions.js `sendReaction` lines 982-988, zaps.js `createZapRequest`
/// lines 822-828).
///
/// Rules (in priority order, matching the PWA):
///  - PM (1:1) or group message → `'1059'` (NIP-17 gift wrap covers both 1:1
///    PMs and group rumor messages for the public-facing kind tag).
///    Group reactions are additionally re-tagged `'14'` inside the gift wrap by
///    the controller, but the inferred message kind is `'1059'`.
///  - Channel message in a named (non-geohash) channel → `'23333'`.
///  - Channel message in a geohash channel → `'20000'` (default).
///
/// [view] is the active [ChatView]; it disambiguates geohash vs named channels
/// the same way the PWA reads `currentGeohash` / `currentChannel`. When the
/// message itself carries a concrete [Message.eventKind] we honour it first.
String inferOriginalKind(Message message, {ChatView? view}) {
  // A PM or group message is always private (gift-wrapped).
  if (message.isPM || message.isGroup || message.groupId != null) {
    return '1059';
  }
  // Honour a concrete event kind on the message when it is one of ours.
  switch (message.eventKind) {
    case 20000:
      return '20000';
    case 23333:
      return '23333';
    case 14:
    case 1059:
      return '1059';
  }
  // Fall back to the active view: a non-geohash (named) channel is 23333,
  // a geohash channel is 20000.
  if (view != null && view.kind == ViewKind.channel) {
    if (message.geohash != null && message.geohash!.isNotEmpty) return '20000';
    if (message.channel != null && message.channel!.isNotEmpty) return '23333';
    // No hint on the message — infer from whether the view id is a geohash.
    return _looksLikeGeohash(view.id) ? '20000' : '23333';
  }
  // Default to geohash channel kind, mirroring the PWA default.
  return '20000';
}

/// The reaction-target pubkey ('p' tag): the message author.
String reactionTargetFor(Message message) => message.pubkey;

/// Loose geohash test mirroring the spirit of the PWA's `isValidGeohash`:
/// base-32 geohash alphabet, 1-12 chars. Used only as a last-resort hint.
bool _looksLikeGeohash(String s) {
  if (s.isEmpty || s.length > 12) return false;
  return RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]+$').hasMatch(s.toLowerCase());
}

/// A pending composer action raised by the context menu. The composer is owned
/// by another slice; rather than editing it, the context menu publishes the
/// requested mention/quote here and the composer reads + consumes it later.
///
/// This is the "mention/quote hook" the spec calls for: a Riverpod
/// [StateNotifierProvider] acting as a one-shot mailbox. The context menu calls
/// [InteractionHooks.requestMention] / [requestQuote]; a future composer slice
/// watches [pendingComposerActionProvider], applies the action, then calls
/// [consume].
sealed class ComposerAction {
  const ComposerAction();
}

/// Insert `@nym ` at the composer caret (ui-context.js `insertMention`).
class MentionAction extends ComposerAction {
  const MentionAction(this.fullNym);

  /// The full `base#suffix` nym to mention.
  final String fullNym;
}

/// Set a quote-reply preview to [content] attributed to [fullNym]
/// (ui-context.js `setQuoteReply`).
class QuoteAction extends ComposerAction {
  const QuoteAction({required this.fullNym, required this.content});
  final String fullNym;
  final String content;
}

/// Holds the most-recent un-consumed composer action (or null).
class InteractionHooks extends StateNotifier<ComposerAction?> {
  InteractionHooks() : super(null);

  void requestMention(String fullNym) => state = MentionAction(fullNym);

  void requestQuote({required String fullNym, required String content}) =>
      state = QuoteAction(fullNym: fullNym, content: content);

  /// Clears the pending action once the composer has applied it.
  void consume() => state = null;
}

/// The mention/quote mailbox. The context menu writes; the composer reads.
final pendingComposerActionProvider =
    StateNotifierProvider<InteractionHooks, ComposerAction?>(
  (ref) => InteractionHooks(),
);

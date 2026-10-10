import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';

/// The `k` tag kind for a reaction or zap: '1059' private, '23333' named channel, '20000' geohash.
String inferOriginalKind(Message message, {ChatView? view}) {
  // PMs and group messages are gift-wrapped.
  if (message.isPM || message.isGroup || message.groupId != null) {
    return '1059';
  }
  switch (message.eventKind) {
    case 20000:
      return '20000';
    case 23333:
      return '23333';
    case 14:
    case 1059:
      return '1059';
  }
  if (view != null && view.kind == ViewKind.channel) {
    if (message.geohash != null && message.geohash!.isNotEmpty) return '20000';
    if (message.channel != null && message.channel!.isNotEmpty) return '23333';
    return _looksLikeGeohash(view.id) ? '20000' : '23333';
  }
  // Defaults to the geohash channel kind, as the PWA does.
  return '20000';
}

String reactionTargetFor(Message message) => message.pubkey;

/// Loose geohash test (base-32 alphabet, 1-12 chars), used only as a last-resort hint.
bool _looksLikeGeohash(String s) {
  if (s.isEmpty || s.length > 12) return false;
  return RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]+$').hasMatch(s.toLowerCase());
}

/// One-shot mailbox the context menu writes and the composer consumes, so neither owns the other.
sealed class ComposerAction {
  const ComposerAction();
}

class MentionAction extends ComposerAction {
  const MentionAction(this.fullNym);

  final String fullNym;
}

class QuoteAction extends ComposerAction {
  const QuoteAction(
      {required this.fullNym, required this.content, this.messageId = ''});
  final String fullNym;
  final String content;
  final String messageId;
}

/// Appends shared text so the user can review it before sending.
class InsertTextAction extends ComposerAction {
  const InsertTextAction(this.text);
  final String text;
}

/// Attaches shared files through the composer's normal upload pipeline.
class ShareFilesAction extends ComposerAction {
  const ShareFilesAction(this.paths);
  final List<String> paths;
}

class SendAsRetryAction extends ComposerAction {
  const SendAsRetryAction(this.placeholder);
  final String placeholder;
}

class SendAsPutBackAction extends ComposerAction {
  const SendAsPutBackAction(this.placeholder);
  final String placeholder;
}

class InteractionHooks extends StateNotifier<ComposerAction?> {
  InteractionHooks() : super(null);

  void requestMention(String fullNym) => state = MentionAction(fullNym);

  void requestQuote(
          {required String fullNym,
          required String content,
          String messageId = ''}) =>
      state = QuoteAction(
          fullNym: fullNym, content: content, messageId: messageId);

  void requestInsertText(String text) => state = InsertTextAction(text);

  void requestShareFiles(List<String> paths) => state = ShareFilesAction(paths);

  void requestSendAsRetry(String placeholder) =>
      state = SendAsRetryAction(placeholder);

  void requestSendAsPutBack(String placeholder) =>
      state = SendAsPutBackAction(placeholder);

  void consume() => state = null;
}

final pendingComposerActionProvider =
    StateNotifierProvider<InteractionHooks, ComposerAction?>(
  (ref) => InteractionHooks(),
);

/// Gift-credits mailbox: the context menu posts a recipient and the nymbot slice opens its modal and consumes it.
class GiftCreditsRequest {
  const GiftCreditsRequest({required this.pubkey, required this.nym});

  final String pubkey;

  /// Base nym without `#suffix`.
  final String nym;
}

class GiftCreditsHooks extends StateNotifier<GiftCreditsRequest?> {
  GiftCreditsHooks() : super(null);

  void request({required String pubkey, required String nym}) =>
      state = GiftCreditsRequest(pubkey: pubkey, nym: nym);

  void consume() => state = null;
}

final giftCreditsRequestProvider =
    StateNotifierProvider<GiftCreditsHooks, GiftCreditsRequest?>(
  (ref) => GiftCreditsHooks(),
);

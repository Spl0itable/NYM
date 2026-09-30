/// Nymbot in channel threads: a plain reply under its message continues the conversation with the thread as context.
library;

import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';

/// The `[gc:BASE64]` token Nymbot carries while a wordplay game is unfinished.
final RegExp _gameTokenRe = RegExp(r'\[gc:[A-Za-z0-9+/=]+\]');

/// Per-entry cap on transcript text sent to the worker.
const int _maxEntryChars = 1000;

/// Matches the worker's `MAX_CONVERSATION_HISTORY`; more just gets trimmed.
const int _maxEntries = 20;

bool _isBotMessage(Message m, String botPubkey) =>
    m.pubkey == botPubkey || m.pubkey.toLowerCase() == botPubkey.toLowerCase();

/// Thread messages for [rootId]: root first, then replies chronologically.
List<Message> threadChainFor(AppState s, String storageKey, String rootId) {
  if (!appThreadsEnabled || rootId.isEmpty) return const <Message>[];
  final root = threadRootMessage(s, storageKey, rootId);
  if (root == null) return const <Message>[];
  return <Message>[root, ...threadRepliesFor(s, storageKey, rootId)];
}

/// Bot message a plain reply answers, only if the bot is the root or last speaker.
Message? threadBotReplyTarget(
  AppState s,
  String storageKey,
  String rootId, {
  String botPubkey = kNymbotPubkey,
}) {
  final chain = threadChainFor(s, storageKey, rootId)
      .where((m) => m.content.trim().isNotEmpty)
      .toList();
  if (chain.isEmpty) return null;
  if (!_isBotMessage(chain.first, botPubkey) &&
      !_isBotMessage(chain.last, botPubkey)) {
    return null;
  }
  final bots = chain.where((m) => _isBotMessage(m, botPubkey)).toList();
  if (bots.isEmpty) return null;
  for (var i = bots.length - 1; i >= 0; i--) {
    if (_gameTokenRe.hasMatch(bots[i].content)) return bots[i];
  }
  return bots.last;
}

/// The leading @mention to strip; the `[gc:]` token stays because ?guess reads the live game from it.
final RegExp _rxBotMention = RegExp(r'^@\S+[ \t]+');
final RegExp _rxZapLine = RegExp(r'^[ \t]*\u26a1.*$', multiLine: true);
final RegExp _rxBlankRun = RegExp(r'\n{3,}');

/// Entry text without the quote block (and for the bot, its @mention and zap prompt) so the model doesn't mimic the format.
String threadEntryText(String content, {bool isBot = false}) {
  var text = content
      .split('\n')
      .where((l) => !l.startsWith('>'))
      .join('\n');
  if (isBot) {
    text = text.replaceFirst(_rxBotMention, '').replaceAll(_rxZapLine, '');
  }
  return text.replaceAll(_rxBlankRun, '\n\n').trim();
}

/// `nym#abcd`, so the worker can tell the bot's turns from humans'.
String threadEntryAuthor(Message m) {
  final base = stripPubkeySuffix(m.author).trim();
  final nym = base.isEmpty ? 'nym' : base;
  return m.pubkey.isEmpty ? nym : '$nym#${getPubkeySuffix(m.pubkey)}';
}

/// Thread transcript as `/api/bot` `{author, text}` entries; [exclude] drops the just-published question.
List<Map<String, String>> threadBotConversation(
  AppState s,
  String storageKey,
  String rootId, {
  String? exclude,
  int limit = _maxEntries,
  String botPubkey = kNymbotPubkey,
}) {
  final entries = <Map<String, String>>[];
  for (final m in threadChainFor(s, storageKey, rootId)) {
    var text = threadEntryText(m.content, isBot: _isBotMessage(m, botPubkey));
    if (text.isEmpty) continue;
    if (text.length > _maxEntryChars) text = text.substring(0, _maxEntryChars);
    entries.add({'author': threadEntryAuthor(m), 'text': text});
  }
  // Normalized like the entries.
  final tail = exclude == null ? '' : threadEntryText(exclude);
  if (tail.isNotEmpty && entries.isNotEmpty && entries.last['text'] == tail) {
    entries.removeLast();
  }
  if (entries.length > limit) {
    return entries.sublist(entries.length - limit);
  }
  return entries;
}

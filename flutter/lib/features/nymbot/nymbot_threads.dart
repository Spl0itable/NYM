/// Nymbot in channel threads: a plain reply under its message continues the conversation with the thread as context.
library;

import '../../core/utils/nick_parse.dart';
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
  return <Message>[
    if (!s.isMessageFiltered(root)) root,
    ...threadRepliesFor(s, storageKey, rootId),
  ];
}

/// Bot message a plain reply answers, only in a thread rooted on a bot message.
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
  if (threadKeyForMessage(chain.first) != rootId ||
      !_isBotMessage(chain.first, botPubkey)) {
    return null;
  }
  final bots = chain.where((m) => _isBotMessage(m, botPubkey)).toList();
  if (bots.isEmpty) return null;
  for (var i = bots.length - 1; i >= 0; i--) {
    if (_gameTokenRe.hasMatch(bots[i].content)) return bots[i];
  }
  return bots.last;
}

final RegExp _rxBlankRun = RegExp(r'\n{3,}');

/// Entry text without the quote block (and for the bot, its @mention and zap prompt) so the model doesn't mimic the format.
String threadEntryText(String content, {bool isBot = false}) {
  var text = content
      .split('\n')
      .where((l) => !l.startsWith('>'))
      .join('\n');
  if (isBot) text = stripNickEnvelope(text);
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
  bool publishedOnly = false,
}) {
  final entries = <Map<String, String>>[];
  for (final m in threadChainFor(s, storageKey, rootId)) {
    if (publishedOnly &&
        (m.optimistic || m.deliveryStatus == DeliveryStatus.failed)) {
      continue;
    }
    var text = threadEntryText(m.content, isBot: _isBotMessage(m, botPubkey));
    if (text.isEmpty) continue;
    if (text.length > _maxEntryChars) text = text.substring(0, _maxEntryChars);
    entries.add({
      'author': threadEntryAuthor(m),
      'text': text,
      if (_hex64.hasMatch(m.pubkey)) 'pubkey': m.pubkey.toLowerCase(),
    });
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

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
final RegExp _rxSpaces = RegExp(r'\s+');

String _flatText(String s) => s.replaceAll(_rxSpaces, ' ').trim();

List<Map<String, String>> markOwnBotEntries(
  List<Map<String, String>> conversation,
  AppState s,
  String storageKey,
  String ownPubkey,
) {
  final pk = ownPubkey.toLowerCase();
  if (!_hex64.hasMatch(pk) || conversation.isEmpty) return conversation;
  final own = <String>{
    for (final m in s.messages[storageKey] ?? const <Message>[])
      if (m.pubkey.toLowerCase() == pk) _flatText(threadEntryText(m.content)),
  }..remove('');
  return [
    for (final e in conversation)
      e.containsKey('pubkey') || !own.contains(_flatText(e['text'] ?? ''))
          ? e
          : {...e, 'pubkey': pk},
  ];
}

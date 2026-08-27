// Nymbot inside CHANNEL message threads (`nymbot_threads.dart`). The free
// channel bot only heard a reply that carried a `?` prefix, an `@Nymbot`
// mention, or a quote of one of its messages — a plain reply typed into a
// thread reached nobody, so a game answered there lost its state. These lock
// in when a thread reply routes to the bot, which of its messages the routing
// reads, and what transcript the worker gets.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/nymbot_threads.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

const _rootId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _humanPk =
    '00000000000000000000000000000000000000000000000000000000000011aa';

Message _bot(String id, int ts, String content, {String? threadRoot}) => Message(
      id: id,
      pubkey: kNymbotPubkey,
      author: 'Nymbot',
      content: content,
      createdAt: ts,
      isBot: true,
      threadRoot: threadRoot,
    );

Message _human(String id, int ts, String content, {String? threadRoot}) =>
    Message(
      id: id,
      pubkey: _humanPk,
      author: 'alice',
      content: content,
      createdAt: ts,
      threadRoot: threadRoot,
    );

AppStateNotifier _store(List<Message> msgs) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');
  n.switchView(const ChatView.channel('room'));
  n.state.messages['#room'] = msgs;
  return n;
}

void main() {
  const now = 1700000000;
  const token = '[gc:dHJpdmlhOnBhcmlz]';

  setUp(() => appThreadsEnabled = true);
  tearDown(() => appThreadsEnabled = true);

  group('threadBotReplyTarget', () {
    test('a thread rooted on Nymbot routes, and the newest game token wins',
        () {
      final n = _store([
        _bot(_rootId, now, 'Trivia: capital of France?\n$token'),
        _human('b' * 64, now + 1, 'london', threadRoot: _rootId),
        _bot('c' * 64, now + 2, 'Not quite! Try again.\n$token',
            threadRoot: _rootId),
      ]);
      final target = threadBotReplyTarget(n.state, '#room', _rootId);
      expect(target!.id, 'c' * 64, reason: 'newest [gc:] message, not the root');
    });

    test('falls back to the newest bot message when no game is in flight', () {
      final n = _store([
        _bot(_rootId, now, 'Here is an answer.'),
        _human('b' * 64, now + 1, 'thanks', threadRoot: _rootId),
        _bot('c' * 64, now + 2, 'Anytime.', threadRoot: _rootId),
      ]);
      expect(threadBotReplyTarget(n.state, '#room', _rootId)!.id, 'c' * 64);
    });

    test('a thread nobody asked the bot into does NOT route', () {
      final n = _store([
        _human(_rootId, now, 'what do you all think?'),
        _human('b' * 64, now + 1, 'no idea', threadRoot: _rootId),
      ]);
      expect(threadBotReplyTarget(n.state, '#room', _rootId), isNull);
    });

    test('a human-rooted thread routes once Nymbot is its last speaker', () {
      final n = _store([
        _human(_rootId, now, 'anyone know?'),
        _bot('b' * 64, now + 1, 'I do — here you go.', threadRoot: _rootId),
      ]);
      expect(threadBotReplyTarget(n.state, '#room', _rootId)!.id, 'b' * 64);
    });

    test('a human replying after the bot stops the auto-routing', () {
      final n = _store([
        _human(_rootId, now, 'anyone know?'),
        _bot('b' * 64, now + 1, 'I do.', threadRoot: _rootId),
        _human('c' * 64, now + 2, 'nice one', threadRoot: _rootId),
      ]);
      expect(threadBotReplyTarget(n.state, '#room', _rootId), isNull);
    });

    test('threads off → never routes', () {
      appThreadsEnabled = false;
      final n = _store([_bot(_rootId, now, 'hi $token')]);
      expect(threadBotReplyTarget(n.state, '#room', _rootId), isNull);
    });
  });

  group('threadBotConversation strips the wire envelope', () {
    const zap = '\n\n\u26a1 Liked this response? Zap this message with a '
        'Bitcoin Lightning tip! If you don\'t know what or how to zap, just ask!';

    test('a quote-reply exchange reaches the worker as what was said', () {
      final reply = _human('e' * 64, now + 3,
          "> @Nymbot#4bb2: @Luxas#a8df Nice, what's new?\n> \n> \u26a1 Liked this...\n\nwhat? that is what I asked you",
          threadRoot: _rootId);
      final n = _store([
        _bot(_rootId, now, "@Luxas#a8df Here's something interesting.$zap"),
        _human('c' * 64, now + 1,
            "> @Nymbot#4bb2: @Luxas#a8df Here's something interesting.\n\nnice, what's new",
            threadRoot: _rootId),
        _bot('d' * 64, now + 2, "@Luxas#a8df Nice, what's new?$zap",
            threadRoot: _rootId),
        reply,
      ]);
      final convo = threadBotConversation(n.state, '#room', _rootId,
          exclude: reply.content);
      expect(convo.any((e) => e['text']!.contains('that is what I asked you')),
          isFalse,
          reason: 'the message just sent must not come back as history');
      expect(convo.any((e) => e['text']!.contains('>')), isFalse);
      expect(convo.any((e) => e['text']!.startsWith('@')), isFalse);
      expect(convo.any((e) => e['text']!.contains('\u26a1')), isFalse);
      expect(convo.map((e) => e['text']), [
        "Here's something interesting.",
        "nice, what's new",
        "Nice, what's new?",
      ]);
    });

    test('an unfinished game token survives the stripping', () {
      final n = _store([
        _bot(_rootId, now, '@Luxas#a8df Trivia?\n[gc:dHJpdmlhOnBhcmlz]$zap'),
        _human('c' * 64, now + 1, 'london', threadRoot: _rootId),
      ]);
      final convo = threadBotConversation(n.state, '#room', _rootId);
      expect(convo.first['text'], contains('[gc:dHJpdmlhOnBhcmlz]'));
      expect(convo.first['text'], isNot(contains('\u26a1')));
    });
  });

  group('threadBotConversation', () {
    test('sends the thread root first, then replies, with nym#suffix authors',
        () {
      final n = _store([
        _bot(_rootId, now, 'Trivia: capital of France?\n$token'),
        _human('b' * 64, now + 1, 'london', threadRoot: _rootId),
      ]);
      final convo = threadBotConversation(n.state, '#room', _rootId);
      expect(convo.map((e) => e['author']),
          ['Nymbot#${kNymbotPubkey.substring(kNymbotPubkey.length - 4)}',
           'alice#11aa']);
      expect(convo.first['text'], contains(token),
          reason: 'the game token must survive to the worker');
      expect(convo.last['text'], 'london');
    });

    test('drops the just-published message when it is already in the store',
        () {
      final n = _store([
        _bot(_rootId, now, 'Trivia?\n$token'),
        _human('b' * 64, now + 1, 'paris', threadRoot: _rootId),
      ]);
      final convo =
          threadBotConversation(n.state, '#room', _rootId, exclude: 'paris');
      expect(convo.length, 1);
      expect(convo.single['author'], startsWith('Nymbot#'));
    });

    test('an unknown root yields nothing (caller falls back to the quote chain)',
        () {
      final n = _store([_bot(_rootId, now, 'hi')]);
      expect(threadBotConversation(n.state, '#room', 'f' * 64), isEmpty);
    });
  });
}

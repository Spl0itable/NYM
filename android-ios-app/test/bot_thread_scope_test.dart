import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

final _self = '1' * 64;
final _peer = '2' * 64;
const _botKey = 'pm-$kNymbotPubkey';
final _appRoot = 'a' * 64;
final _myRoot = 'b' * 64;

Message _pm(
  String id,
  int ts, {
  bool own = false,
  String? threadRoot,
  String? nymMessageId,
  String peer = kNymbotPubkey,
}) =>
    Message(
      id: id,
      author: own ? 'me#0001' : 'Nymbot',
      pubkey: own ? _self : peer,
      content: 'msg $id',
      createdAt: ts,
      isOwn: own,
      isPM: true,
      conversationKey: 'pm-$peer',
      conversationPubkey: peer,
      eventKind: 1059,
      nymMessageId: nymMessageId ?? 'x$id',
      threadRoot: threadRoot,
      isBot: !own && peer == kNymbotPubkey,
    );

void main() {
  const now = 1700000000;

  setUp(() => appThreadsEnabled = true);
  tearDown(() => appThreadsEnabled = true);

  AppStateNotifier live(ProviderContainer c) =>
      c.read(appStateProvider.notifier)..goLive(_self, 'me#0001');

  group('a chat made in the Nymbot app', () {
    test('is held out of the bot conversation', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      n.ingestPMMessage(_pm('plain', now));
      final unread = n.state.unreadCounts[kNymbotPubkey];
      final reply = _pm('app-reply', now + 1, threadRoot: _appRoot);
      final question = _pm('app-q', now + 2, own: true, threadRoot: _appRoot);
      expect(n.holdForeignBotThread(reply), isTrue);
      expect(n.holdForeignBotThread(question), isTrue);
      final ids = n.state.messages[_botKey]!.map((m) => m.id);
      expect(ids, ['plain']);
      expect(visibleMessagesFor(n.state, _botKey).map((m) => m.id), ['plain']);
      expect(n.state.unreadCounts[kNymbotPubkey], unread);
    });

    test('is dropped even when it reaches the store directly', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      n.ingestPMMessage(_pm('plain', now));
      n.ingestPMMessage(_pm('app-reply', now + 1, threadRoot: _appRoot));
      expect(n.state.messages[_botKey]!.map((m) => m.id), ['plain']);
    });

    test('is pruned from what an older version cached', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      n.hydrateMessages(_botKey, [
        _pm('plain', now),
        _pm('app-reply', now + 1, threadRoot: _appRoot),
        _pm('root', now + 2, own: true, nymMessageId: _myRoot),
        _pm('mine', now + 3, threadRoot: _myRoot),
      ]);
      expect(n.state.messages[_botKey]!.map((m) => m.id),
          ['plain', 'root', 'mine']);
      expect(visibleMessagesFor(n.state, _botKey).map((m) => m.id),
          ['plain', 'root']);
      expect(threadRepliesFor(n.state, _botKey, _myRoot).single.id, 'mine');
    });

    test('is the only thing a missing root hides', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      final human = _pm('h', now, threadRoot: _appRoot, peer: _peer);
      expect(n.holdForeignBotThread(human), isFalse);
      n.ingestPMMessage(human);
      expect(visibleMessagesFor(n.state, 'pm-$_peer').single.id, 'h');
      n.state.messages[_botKey] = [
        _pm('plain', now),
        _pm('app-reply', now + 1, threadRoot: _appRoot),
      ];
      appThreadsEnabled = false;
      expect(visibleMessagesFor(n.state, _botKey).map((m) => m.id), ['plain']);
    });
  });

  group('a thread this app opened on the bot', () {
    test('keeps its replies', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      n.ingestPMMessage(_pm('root', now, own: true, nymMessageId: _myRoot));
      final reply = _pm('reply', now + 1, threadRoot: _myRoot);
      expect(n.holdForeignBotThread(reply), isFalse);
      n.ingestPMMessage(reply);
      expect(n.state.messages[_botKey]!.map((m) => m.id), ['root', 'reply']);
      expect(visibleMessagesFor(n.state, _botKey).map((m) => m.id), ['root']);
      expect(threadRepliesFor(n.state, _botKey, _myRoot).single.id, 'reply');
    });

    test('files a reply that arrives before its root once the root lands', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = live(c);
      final reply = _pm('reply', now + 1, threadRoot: _myRoot);
      expect(n.holdForeignBotThread(reply), isTrue);
      expect(n.state.messages[_botKey], anyOf(isNull, isEmpty));
      n.ingestPMMessage(_pm('root', now, own: true, nymMessageId: _myRoot));
      expect(n.state.messages[_botKey]!.map((m) => m.id), ['root', 'reply']);
      expect(threadRepliesFor(n.state, _botKey, _myRoot).single.id, 'reply');
      n.ingestPMMessage(
          _pm('root2', now + 5, own: true, nymMessageId: _myRoot));
      expect(n.state.messages[_botKey]!.length, 2);
    });
  });
}
